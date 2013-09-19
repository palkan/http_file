%%% @doc
%%% Module to download or read files over HTTP(S).
%%%
%%% Should be able to download files by chunks in parallel (if possible). Not implemented now.
%%% @end

-module(http_file).
-define(D(X), io:format("DEBUG ~p:~p ~p~n", [?MODULE, ?LINE, X])).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([open/2, download/2, pread/3, file_size/1, close/1]).

%% temp
-export([match_requests/2, update_map/4, glue_map/1]).

-behaviour(gen_server).

-record(http_file, {
  url,
  cache_file,
  options,
  caller,
  streams = [],
  chunk_size,
  size = 0,
  loaded_size = 0,
  ranged = false
}).


%% @doc
%% Send 'HEAD' request and initiate process or fail if http error occurred.
%% Doesn't start downloading.
%% @end

-spec open(string(), list()) -> {ok, pid()}
|{error, Reason :: any()}. %% http error occurred

open(URL, Options) ->
  gen_server:start_link(?MODULE, [URL, Options], []).

%% @doc
%% Download file (synchronously);
%% return {ok,Size} if download completed;
%% return {error,Code} if smth goes wrong
%% @todo implement async download with receiving process
%% @end

-spec download(string(), list()) -> {ok, Size :: non_neg_integer()}
|{error, Reason :: any()}. %% http error occurred

download(URL, Options) ->
  ?D(download),
  case gen_server:start_link(?MODULE, [URL, Options], []) of
    {ok, Pid} -> gen_server:call(Pid, download, infinity);
    Else -> Else
  end.


%% @doc
%% Partial read file over HTTP.
%% @todo implement
%% @end

-spec pread(pid(), non_neg_integer(), non_neg_integer()) -> {ok, binary()} | {error, Reason :: any()}.

pread(File, Offset, Limit) ->
  gen_server:call(File, {pread, Offset, Limit}).

%% @doc
%% Get file size.
%% @end

-spec file_size(pid()) -> non_neg_integer().

file_size(File) ->
  gen_server:call(File, size).


close(File) ->
  gen_server:cast(File, close),
  ok.


init([URL, Options]) ->
  case ibrowse:send_req(URL, [], head, [], []) of
    {ok, "200", Headers, _} ->
      Size = list_to_integer(proplists:get_value("Content-Length", Headers, "0")),
      CacheName = proplists:get_value(cache_file, Options),
      Options2 = case proplists:get_value(strategy,Options,null) of
                   null -> Options;
                   Fun -> {Chunked_,Streams_} = Fun(Size),
                     proplists:expand(Options,[{chunked,Chunked_},{streams,Streams_}])
                 end,
      Chunked = proplists:get_value(chunked, Options2, true),
      Ranged = case proplists:get_value("Accept-Ranges", Headers, undef) of
                 "bytes" -> true and Chunked;
                 _ -> false
               end,
      {ok, CacheFile} = http_file_writer:start(CacheName, Size),
      {ok, #http_file{url = URL, cache_file = CacheFile, options = Options2, size = Size, ranged = Ranged}};
    {_, Code, _, _} -> ?D(Code), {stop, {http_error, Code}}
  end.


handle_call(size, _From, #http_file{size = Size} = File) ->
  {reply, Size, File};

handle_call({pread, Offset, Limit}, From, #http_file{streams = Streams} = File) ->
  case is_data_cached(Streams, Offset, Limit) of
    true ->
      {reply, fetch_cached_data(File, Offset, Limit), File};
    false ->
      File1 = schedule_request(File, {From, Offset, Limit}),
      {noreply, File1}
  end;

handle_call(download, From, #http_file{size = Size, ranged = true, options = Options} = File) ->
  StreamNum = proplists:get_value(streams, Options, 4),
  ChunkSize = min(Size, 1024 * 1024),
  [self() ! start_stream || _S <- lists:seq(1, StreamNum)],
  {noreply, File#http_file{chunk_size = ChunkSize, caller = From}};

handle_call(download, From, #http_file{ranged = false} = File) ->
  self() ! start_stream,
  {noreply, File#http_file{caller = From}};

handle_call(Unknown, From, File) ->
  ?D({unknown_call, Unknown, From, File}),
  {stop, {error, unknown_call, Unknown}, File}.

handle_cast(close, State) ->
  {stop, normal, State};

handle_cast(_, State) ->
  {noreply, State}.


handle_info(start_stream, #http_file{size = Size, loaded_size = Loaded} = State) when Loaded == Size ->
  {noreply, State};

handle_info(start_stream, #http_file{url = Url, chunk_size = ChunkSize, size = Size, streams = Streams, loaded_size = Loaded, ranged = true} = State) ->
  Amount = if (Size - Loaded > ChunkSize)
    -> ChunkSize;
    true -> Size - Loaded
  end,
  Bound = Loaded + Amount - 1,
  ?D({start_stream, Loaded, Bound}),
  {ibrowse_req_id, ReqId} = ibrowse:send_req(Url, [{"Range", lists:flatten(io_lib:format("bytes=~p-~p", [Loaded, Bound]))}], get, [], [{stream_to, self()}]),
  NewStreams = lists:keystore(ReqId, 1, Streams, {ReqId, Loaded, Bound}),
  {noreply, State#http_file{streams = NewStreams, loaded_size = Bound + 1}};

handle_info(start_stream, #http_file{url = Url, ranged = false, size = Size} = State) ->
  {ibrowse_req_id, ReqId} = ibrowse:send_req(Url, [], get, [], [{stream_to, self()}], 120000),
  {noreply, State#http_file{streams = [{ReqId,0,Size-1}], loaded_size = Size}};


handle_info({ibrowse_async_headers, ReqId, [$4, _, _] = Code, _Headers}, #http_file{streams = Streams, caller = Caller} = State) ->
  case lists:keyfind(ReqId, 1, Streams) of
    {_, _, _} -> gen_server:reply(Caller, {error, Code}),
      {stop, normal, State};
    _ ->
      ?D({undefined_stream, ReqId}),
      {noreply, State}
  end;

handle_info({ibrowse_async_headers, _ReqId, _Code, _Headers}, State) ->
  ?D(_Code),
  {noreply, State};

handle_info({ibrowse_async_response, ReqId, Bin}, #http_file{streams = Streams, cache_file = Cache} = State) ->
  NewStreams = case lists:keyfind(ReqId, 1, Streams) of
    {_, Offset, Size} -> BSize = length(Bin),
                          ?D({response, BSize, Size}),
                          Cache ! {data,Offset,Bin},
                          lists:keystore(ReqId,1,Streams,{ReqId,Offset+BSize,Size - BSize});
    _ ->
      ?D({undefined_stream, ReqId}),
      Streams
  end,
  {noreply, State#http_file{streams = NewStreams}};


handle_info({ibrowse_async_response_end, ReqId}, #http_file{size = Size, loaded_size = Loaded, streams = Streams} = State) when Loaded == Size ->
  NewStreams = case lists:keyfind(ReqId, 1, Streams) of
                 {_, _, _} -> lists:keydelete(ReqId, 1, Streams);
                 _ -> Streams
               end,
  {noreply, State#http_file{streams = NewStreams}};

handle_info({ibrowse_async_response_end, ReqId}, #http_file{streams = Streams} = State) ->
  NewStreams = case lists:keyfind(ReqId, 1, Streams) of
                 {_, _, _} -> lists:keydelete(ReqId, 1, Streams);
                 _ -> Streams
               end,
  self() ! start_stream,
  {noreply, State#http_file{streams = NewStreams}};


handle_info({ibrowse_async_response_timeout, ReqId}, #http_file{streams = Streams, url = Url, ranged = false, size = Size} = State) ->
  NewStreams = case lists:keyfind(ReqId, 1, Streams) of
                 {_, _, _} -> Streams2 = lists:keydelete(ReqId, 1, Streams),
                   ?D({increase_timeout, 0, Size}),
                   {ibrowse_req_id, ReqId2} = ibrowse:send_req(Url, [], get, [], [{stream_to, self()}], 240000),
                   lists:keystore(ReqId2, 1, Streams2, {ReqId2, 0, Size-1});
                 _ -> Streams
               end,
  {noreply, State#http_file{streams = NewStreams}};

handle_info({ibrowse_async_response_timeout, ReqId}, #http_file{streams = Streams, url = Url} = State) ->
  NewStreams = case lists:keyfind(ReqId, 1, Streams) of
                 {_, Offset, Size} -> Streams2 = lists:keydelete(ReqId, 1, Streams),
                   ?D({increase_timeout, Offset, Size}),
                   {ibrowse_req_id, ReqId2} = ibrowse:send_req(Url, [{"Range", lists:flatten(io_lib:format("bytes=~p-~p", [Offset, Size]))}], get, [], [{stream_to, self()}], 120000),
                   lists:keystore(ReqId2, 1, Streams2, {ReqId2, Offset, Size});
                 _ -> Streams
               end,
  {noreply, State#http_file{streams = NewStreams}};

handle_info({http_file_write_complete,Cache},#http_file{caller = Caller, cache_file = Cache,loaded_size = Size}=State) ->
  gen_server:reply(Caller,{ok,Size}),
  {stop, normal, State};

handle_info(Message, State) ->
  ?D({unknown_msg, Message}),
  {noreply, State}.


terminate(_Reason, _State) ->
  ok.

code_change(_Old, State, _Extra) ->
  {ok, State}.

%%%----------------------------



schedule_request(File, {_From, _Offset, _Limit} = _Request) ->
  File.


fetch_cached_data(#http_file{cache_file = Cache}, Offset, Limit) ->
  file:pread(Cache, Offset, Limit).

update_map(Streams, Stream, Offset, Size) ->
  {value, Entry, Streams1} = lists:keytake(Stream, 1, Streams),
  {Stream, OldOffset, OldSize} = Entry,
  Offset = OldOffset + OldSize,
  NewEntry = {Stream, OldOffset, OldSize + Size},
  lists:ukeymerge(1, [NewEntry], Streams1).


glue_map(Streams) ->
  Sorted = lists:keysort(2, Streams),
  glue_map(Sorted, [], []).

glue_map([Stream], NewStreams, Removed) ->
  {lists:keysort(1, [Stream|NewStreams]), lists:sort(Removed)};

glue_map([Stream1, Stream2 | Streams], NewStreams, Removed) ->
  case intersect(Stream1, Stream2) of
    {leave, R1, R2} ->
      glue_map([R2|Streams], [R1 | NewStreams], Removed);
    {remove, R1, Key} ->
      glue_map([R1|Streams], NewStreams, [Key|Removed])
  end.

%%   Start1....End1   Start2...End2
intersect({_Key1, Offset1, Size1} = R1, {_Key2, Offset2, _Size2} = R2)
  when Offset1 + Size1 < Offset2 ->
  {leave, R1, R2};

%%   Start1....Start2...End1...End2
intersect({Key1, Offset1, Size1}, {Key2, Offset2, Size2})
  when Offset1 + Size1 >= Offset2 andalso Offset1 + Size1 < Offset2 + Size2 ->
  {remove, {Key2, Offset1, Offset2 + Size2 - Offset1}, Key1};


%%   Start1....Start2...End2...End1
intersect({_Key1, Offset1, Size1} = R1, {Key2, Offset2, Size2})
  when Offset1 + Size1 >= Offset2 andalso Offset1 + Size1 >= Offset2 + Size2 ->
  {remove, R1, Key2}.


match_requests(Requests, Streams) ->
  match_requests(Requests, Streams, [], []).

match_requests([], _Streams, NewRequests, Replies) ->
  {NewRequests, Replies};

match_requests([{unknown, Offset, Size}|Requests], Streams, NewRequests, Replies) ->
  match_requests(Requests, Streams, [{unknown, Offset, Size}|NewRequests], Replies);

match_requests([{From, Offset, Size}|Requests], Streams, NewRequests, Replies) ->
  case is_data_cached(Streams, Offset, Size) of
    true ->
      match_requests(Requests, Streams, NewRequests, [{From, Offset, Size}|Replies]);
    false ->
      match_requests(Requests, Streams, [{From, Offset, Size}|NewRequests], Replies)
  end.


is_data_cached([], _Offset, _Size) ->
  false;

is_data_cached([{_Request, CurrentOffset, CurrentSize} | _], Offset, Size)
  when Offset >= CurrentOffset andalso Offset + Size =< CurrentOffset + CurrentSize ->
  true;

is_data_cached([_ | Streams], Offset, Size) ->
  is_data_cached(Streams, Offset, Size).


-ifdef(TEST).
%%
%% Tests
%%
-include_lib("eunit/include/eunit.hrl").

update_map1_test() ->
  Map1 = [{a, 0, 10}],
  ?assertEqual([{a, 0, 20}], update_map(Map1, a, 10, 10)).

update_map2_test() ->
  Map1 = [{a, 0, 10}, {b, 15, 15}],
  ?assertEqual([{a, 0, 20}, {b, 15, 15}], update_map(Map1, a, 10, 10)).


is_data_cached_test() ->
  Map1 = [{a, 0, 10}, {b, 15, 15}],
  ?assertEqual(true, is_data_cached(Map1, 0, 10)),
  ?assertEqual(true, is_data_cached(Map1, 17, 5)),
  ?assertEqual(false, is_data_cached(Map1, 0, 25)),
  ?assertEqual(false, is_data_cached(Map1, 9, 2)),
  ?assertEqual(true, is_data_cached(Map1, 9, 1)).



intersect_test() ->
  ?assertEqual({remove, {b, 0, 30}, a}, intersect({a, 0, 20}, {b, 20, 10})),
  ?assertEqual({leave, {a, 0, 18}, {b, 20, 10}}, intersect({a, 0, 18}, {b, 20, 10})),
  ?assertEqual({remove, {a, 0, 45}, b}, intersect({a, 0, 45}, {b, 20, 10})).

glue_map1_test() ->
  Map = [{a, 0, 20}, {b, 20, 10}],
  ?assertEqual({[{b, 0, 30}], [a]}, glue_map(Map)).


glue_map2_test() ->
  Map = [{a, 0, 25}, {b, 20, 10}],
  ?assertEqual({[{b, 0, 30}], [a]}, glue_map(Map)).


glue_map3_test() ->
  Map = [{a, 0, 45}, {b, 20, 10}, {c, 32, 6}],
  ?assertEqual({[{a, 0, 45}], [b, c]}, glue_map(Map)).

glue_map4_test() ->
  Map = [{a, 0, 31}, {b, 20, 10}, {c, 35, 100}],
  ?assertEqual({[{a, 0, 31}, {c, 35, 100}], [b]}, glue_map(Map)).


-endif.







 
  

