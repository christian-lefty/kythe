#
# Copyright 2016 Google Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# Bazel rules to extract Go compilations from library targets for testing the
# Go cross-reference indexer.

# We depend on the Go toolchain to identify the effective OS and architecture
# settings and to resolve standard library packages.
load(
    "@io_bazel_rules_go//go:def.bzl",
    "go_environment_vars",
    "go_library",
    "go_library_attrs",
)

# Emit a shell script that sets up the environment needed by the extractor to
# capture dependencies and runs the extractor.
def _emit_extractor_script(ctx, script, output, srcs, deps, ipath):
  env     = go_environment_vars(ctx) # for GOOS and GOARCH
  tmpdir  = output.dirname + '/tmp'
  srcdir  = tmpdir + '/src/' + ipath
  pkgdir  = tmpdir + '/pkg/%s_%s' % (env['GOOS'], env['GOARCH'])
  outpack = output.path + '_pack'
  cmds    = ['set -e',
             'mkdir -p ' + pkgdir, 'mkdir -p ' + srcdir]

  # Link the source files and dependencies into a common temporary directory.
  # Source files need to be made relative to the temp directory.
  ups = srcdir.count('/') + 1
  cmds += ['ln -s "%s%s" "%s"' % ('../'*ups, src.path, srcdir)
           for src in srcs]
  for path, dpath in deps.items():
    fullpath = '/'.join([pkgdir, dpath])
    tups = fullpath.count('/')
    cmds += [
        'mkdir -p ' + fullpath.rsplit('/', 1)[0],
        "ln -s '%s%s' '%s.a'" % ('../'*tups, path, fullpath),
    ]

  # Invoke the extractor on the temp directory.
  goroot = '/'.join(ctx.files._goroot[0].path.split('/')[:-2])
  cmds.append(' '.join([
      ctx.files._extractor[-1].path,
      '-output_dir', outpack,
      '-goroot', goroot,
      '-gopath', tmpdir,
      '-bydir',
      srcdir,
  ]))

  # Pack the results into a ZIP archive, so we have a single output.
  cmds += [
      'cd ' + output.dirname,
      "zip -qr '%s' '%s'" % (output.basename, output.basename+'_pack'),
      '',
  ]

  f = ctx.new_file(ctx.configuration.bin_dir, script)
  ctx.file_action(output=f, content='\n'.join(cmds), executable=True)
  return f

def _go_indexpack(ctx):
  depfiles= [dep.go_library_object for dep in ctx.attr.library.direct_deps]
  deps   = {dep.path: ctx.attr.library.transitive_go_importmap[dep.path]
            for dep in depfiles}
  srcs   = list(ctx.attr.library.go_sources)
  tools  = ctx.files._goroot + ctx.files._extractor
  output = ctx.outputs.archive
  ipath  = ctx.attr.import_path
  if not ipath:
    ipath = srcs[0].path.rsplit('/', 1)[0]

  script = _emit_extractor_script(ctx, ctx.label.name+'-extract.sh',
                                  output, srcs, deps, ipath)
  ctx.action(
      mnemonic   = 'GoIndexPack',
      executable = script,
      outputs    = [output],
      inputs     = srcs + depfiles + tools,
  )
  return struct(zipfile = output)

_library_providers = [
    "go_sources",
    "go_library_object",
    "direct_deps",
    "transitive_go_importmap",
]

# Generate an index pack with the compilations captured from a single Go
# library or binary rule. The output is written as a single ZIP file that
# contains the index pack directory.
go_indexpack = rule(
    _go_indexpack,
    attrs = {
        "library": attr.label(
            providers = _library_providers,
            mandatory = True,
        ),

        # The import path to attribute to the compilation.
        # If omitted, use the base name of the source directory.
        "import_path": attr.string(),

        # The location of the Go extractor binary.
        "_extractor": attr.label(
            default = Label("//kythe/go/extractors/cmd/gotool"),
            executable = True,
            cfg = "target",
        ),

        # The location of the Go toolchain, needed to resolve standard
        # library packages.
        "_goroot": attr.label(
            default = Label("@io_bazel_rules_go_toolchain//:toolchain"),
        ),
    },
    fragments = ["cpp"],  # required to isolate GOOS and GOARCH
    outputs = {"archive": "%{name}.zip"},
)

def _go_verifier_test(ctx):
  pack     = ctx.attr.indexpack.zipfile
  indexer  = ctx.files._indexer[-1]
  verifier = ctx.file._verifier
  vargs    = ['--use_file_nodes', '--show_goals']
  if ctx.attr.log_entries:
    vargs.append('--show_protos')
  cmds = ['set -e', 'set -o pipefail', ' '.join([
      indexer.short_path, '-zip', pack.short_path,
      '\\\n|', verifier.short_path,
  ] + vargs), '']
  ctx.file_action(output=ctx.outputs.executable,
                  content='\n'.join(cmds), executable=True)
  return struct(
      runfiles = ctx.runfiles([indexer, verifier, pack]),
  )

# Run the Kythe verifier on the output that results from invoking the Go
# indexer on the output of a go_indexpack rule.
go_verifier_test = rule(
    _go_verifier_test,
    attrs = {
        # The go_indexpack output to pass to the indexer.
        "indexpack": attr.label(
            providers = ["zipfile"],
            mandatory = True,
        ),

        # Whether to log the input entries to the verifier.
        "log_entries": attr.bool(default = False),

        # The location of the Go indexer binary.
        "_indexer": attr.label(
            default = Label("//kythe/go/indexer/cmd/go_indexer"),
            executable = True,
            cfg = "data",
        ),

        # The location of the Kythe verifier binary.
        "_verifier": attr.label(
            default = Label("//kythe/cxx/verifier"),
            executable = True,
            single_file = True,
            cfg = "data",
        ),
    },
    test = True,
)

# A convenience macro to generate a test library, pass it to the Go indexer,
# and feed the output of indexing to the Kythe schema verifier.
def go_indexer_test(name, srcs, deps=[], import_path='',
                    log_entries=False, size='small'):
  testlib = name+'_lib'
  go_library(
      name = testlib,
      srcs = srcs,
      deps = deps,
  )
  testpack = name+'_pack'
  go_indexpack(
      name = testpack,
      library = ':'+testlib,
      import_path = import_path,
  )
  go_verifier_test(
      name = name,
      size = size,
      indexpack = ':'+testpack,
      log_entries = log_entries,
  )
