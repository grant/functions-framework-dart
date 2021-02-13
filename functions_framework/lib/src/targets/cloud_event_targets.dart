// Copyright 2021 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:async';

import 'package:shelf/shelf.dart';

import '../bad_request_exception.dart';
import '../cloud_event.dart';
import '../function_config.dart';
import '../function_target.dart';
import '../json_request_utils.dart';
import '../request_context.dart';
import '../typedefs.dart';

abstract class _CloudEventFunctionTarget<T> extends FunctionTarget {
  const _CloudEventFunctionTarget(String target) : super(target);

  Future<CloudEvent<T>> _eventFromRequest(Request request) async =>
      _requiredBinaryHeader.every(request.headers.containsKey)
          ? await _decodeBinary(request, _decode)
          : await _decodeStructured(request, _decode);

  T _decode(Object json) => json as T;
}

class CloudEventFunctionTarget<T> extends _CloudEventFunctionTarget<T> {
  final CloudEventHandler<T> function;

  @override
  FunctionType get type => FunctionType.cloudevent;

  @override
  FutureOr<Response> handler(Request request) async {
    final event = await _eventFromRequest(request);
    await function(event);
    return Response.ok('');
  }

  const CloudEventFunctionTarget(String target, this.function) : super(target);
}

class CloudEventWithContextFunctionTarget<T>
    extends _CloudEventFunctionTarget<T> {
  final CloudEventWithContextHandler<T> function;

  @override
  FunctionType get type => FunctionType.cloudevent;

  @override
  Future<Response> handler(Request request) async {
    final event = await _eventFromRequest(request);
    final context = contextForRequest(request);
    await function(event, context);
    return Response.ok('', headers: context.responseHeaders);
  }

  const CloudEventWithContextFunctionTarget(String target, this.function)
      : super(target);
}

Future<CloudEvent<T>> _decodeStructured<T>(
  Request request,
  T Function(Object json) fromJsonT,
) async {
  final type = mediaTypeFromRequest(request);

  mustBeJson(type);
  var jsonObject = await decodeJson(request) as Map<String, dynamic>;

  if (!jsonObject.containsKey('datacontenttype')) {
    jsonObject = {
      ...jsonObject,
      'datacontenttype': type.toString(),
    };
  }

  return _decodeValidCloudEvent(
    jsonObject,
    'structured-mode message',
    fromJsonT,
  );
}

const _cloudEventPrefix = 'ce-';
const _clientEventPrefixLength = _cloudEventPrefix.length;

Future<CloudEvent<T>> _decodeBinary<T>(
  Request request,
  T Function(Object json) fromJsonT,
) async {
  final type = mediaTypeFromRequest(request);
  mustBeJson(type);

  final map = <String, Object>{
    for (var e in request.headers.entries
        .where((element) => element.key.startsWith(_cloudEventPrefix)))
      e.key.substring(_clientEventPrefixLength): e.value,
    'datacontenttype': type.toString(),
    'data': await decodeJson(request),
  };

  return _decodeValidCloudEvent(map, 'binary-mode message', fromJsonT);
}

CloudEvent<T> _decodeValidCloudEvent<T>(
  Map<String, dynamic> map,
  String messageType,
  T Function(Object json) fromJsonT,
) {
  try {
    return CloudEvent.fromJson(map, fromJsonT);
  } catch (e, stackTrace) {
    throw BadRequestException(
      400,
      'Could not decode the request as a $messageType.',
      innerError: e,
      innerStack: stackTrace,
    );
  }
}

const _requiredBinaryHeader = {
  'ce-type',
  'ce-specversion',
  'ce-source',
  'ce-id',
};
