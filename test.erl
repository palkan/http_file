#! /usr/local/bin/escript
%%! -pa ebin


main(["test"]) ->
  http_file:test();

main([URL]) ->
  main([URL, "tmp/file"]);

main([URL, Local]) ->
  Self = self(),
  spawn(fun() ->
    Start = os:timestamp(),
    {ok,Size} = http_file:download(URL, [{cache_file, Local}]),
    Stop = os:timestamp(),
    io:format("File Downloaded Size: ~p~n", [Size]),
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
  
  