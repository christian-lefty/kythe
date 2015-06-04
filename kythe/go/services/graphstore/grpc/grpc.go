/*
 * Copyright 2015 Google Inc. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Package grpc registers the "grpc" kind to the gsutil package.
package grpc

import (
	"kythe.io/kythe/go/services/graphstore"
	"kythe.io/kythe/go/storage/gsutil"

	"golang.org/x/net/context"
	"google.golang.org/grpc"

	spb "kythe.io/kythe/proto/storage_proto"
)

func init() {
	gsutil.Register("grpc", handler)
}

func handler(spec string) (graphstore.Service, error) {
	conn, err := grpc.Dial(spec)
	if err != nil {
		return nil, err
	}
	return graphstore.GRPC(context.Background(), spb.NewGraphStoreClient(conn)), nil
}