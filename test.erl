#! /usr/local/bin/escript
%%! -pa ebin


main(["test"]) ->
  http_file:test();

main([URL]) ->
  main([URL, "temp_file"]);

main([URL, Local]) ->
  File = http_file:open(URL, [{cache_file, Local}]),

  Self = self(),

  Limit = http_file:file_size(File),

  io:format("File Size: ~p~n", [Limit]),

  %spawn(fun() ->
  %  {ok, Result} = http_file:pread(File, 0, Limit),
  %  io:format("~p~n", [size(Result)]),
  %  Self ! tick
  %end),

  %  spawn(fun() ->
  %    {ok, Result} = http_file:pread(File, 5500000, Limit),
  %    io:format("~p~n", [size(Result)]),
  %    Self ! tick
  %  end),

  spawn(fun() ->
    Start = os:timestamp(),
    {ok, Result} = http_file:pread(File, 0, Limit-1),
    Stop = os:timestamp(),
    io:format("~p~n", [size(Result)]),
    io:format("Start: ~p; Stop: ~p~n", [Start, Stop]),
    Self ! tick
  end),

  wait(1).

wait(0) ->
  ok;

wait(N) ->
  receive
    tick -> wait(N - 1)
  end.
  
  