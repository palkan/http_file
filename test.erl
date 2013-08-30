#! /usr/local/bin/escript
%%! -pa ebin


main(["test"]) ->
  http_file:test();

main([URL]) ->
  main(["D", URL, "tmp/file"]);

main(["D", URL, Local]) ->

  io:format("Download ~p to ~p", [URL,Local]),

  Self = self(),
  spawn(fun() ->
    Start = os:timestamp(),
    io:format("Start ~p", [Start]),
    case http_file:download(URL, [{cache_file, Local}]) of
      {ok, Size} ->  io:format("File Downloaded Size: ~p~n", [Size]);
      {error, Code} -> io:format("File Downloaded Error: ~p~n", [Code])
    end,
    Stop = os:timestamp(),
    io:format("Start: ~p; Stop: ~p~n", [Start, Stop]),
    Self ! tick
  end),

  wait(1);

main(["P", URL, Local]) ->
  Self = self(),

  case http_file:open(URL, [{cache_file, Local}]) of
    {ok, Pid} ->  Size = http_file:file_size(Pid),
                  io:format("File Downloaded Size: ~p~n", [Size]),
                  spawn(fun() ->
                    Start = os:timestamp(),
                    case http_file:pread(Pid, 10000000, 1024) of
                        {ok,Data} -> io:format("Downloaded size: ~p~n", [size(Data)]);
                        {error, Code} -> io:format("File Progress Error: ~p~n", [Code])
                    end,
                    Stop = os:timestamp(),
                    io:format("Start: ~p; Stop: ~p~n", [Start, Stop]),
                    Self ! tick
                  end),
                  wait(1);
    {error, Code} -> io:format("File Downloaded Error: ~p~n", [Code])
  end.

wait(0) ->
  ok;

wait(N) ->
  receive
    tick -> wait(N - 1)
  end.
  
  