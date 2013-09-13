%%% @doc
%%% Background file write.
%%% @end
-module(http_file_writer).
%-define(D(X), io:format("DEBUG ~p:~p ~p~n",[?MODULE, ?LINE, X])).
-define(D(X),0).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([start/2]).
-behaviour(gen_server).


-record(http_file_writer, {
  file ::pid(),
  path ::string(),
  expected_size ::non_neg_integer(),
  size_written = 0,
  request_id ::pid()
}).

%% @doc
%% @end

-spec start(Path::string(), Size::non_neg_integer()) -> {ok,pid()} | {error, Reason::any()}.

start(Path, Size) ->
  gen_server:start_link(?MODULE, [Path,Size,self()], []).

init([Path, Size, ReqId]) ->
  {ok, File} = file:open(Path, [write, read, binary]),
  {ok, #http_file_writer{file = File, path = Path, expected_size = Size, request_id = ReqId}}.


handle_call(_Unknown, _From, State) ->
  {reply, unknown, State}.


handle_cast(_Cast, State) ->
  {noreply, State}.  


handle_info({data, Offset, Bin}, #http_file_writer{file = File, expected_size = Size, size_written = Written, request_id = ReqId} = State) ->
  ok = file:pwrite(File, Offset, Bin),
  NewWritten = Written+bsize(Bin),
  if Size == NewWritten
    ->  file:close(File),
        ReqId ! {http_file_write_complete,self()};
    true -> ok
  end,
  {noreply, State#http_file_writer{size_written = NewWritten}};

handle_info(stop, #http_file_writer{file = File, path = Path, size_written = 0} = State) ->
  ?D({"Stopped empty", State}),
  file:close(File),
  file:delete(Path),
  {stop, normal, State};

handle_info(stop, #http_file_writer{file = File} = State) ->
  ?D({"Stopped", State}),
  file:close(File),
  {stop, normal, State};

handle_info(Message, State) ->
  ?D({unknowm_msg, Message}),
  {noreply, State}.


terminate(_Reason, _State) ->
  ok.

code_change(_Old, State, _Extra) ->
  {ok, State}.
  

bsize(B) when is_binary(B) ->
  size(B);

bsize(B) ->
  length(B).
