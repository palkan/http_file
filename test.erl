#! /usr/local/bin/escript
%%! -pa ebin -pa ../ibrowse/ebin -pa ../ulitos/ebin


main(["test"]) ->
  http_file:test();


main([URL]) ->
  main([URL, "file.tmp","4"]);

main([URL,Local]) ->
  main([URL,Local,"4"]);

main([URL, Local, Streams]) ->

  StreamsN = list_to_integer(Streams),

  Options = if StreamsN == 0
      -> [{cache_file, Local},{chunked,false}];
     true -> [{cache_file, Local},{streams,StreamsN}]
  end,

  ibrowse:start(),

  io:format("Download ~p to ~p~n", [URL,Local]),

  Self = self(),
  spawn(fun() ->
    Start = ulitos:timestamp(),
    io:format("Start ~p~n", [Start]),
    case http_file:download(URL, Options) of
      {ok, Size} ->  io:format("File Downloaded Size: ~p~n", [Size]);
      {error, Code} -> io:format("File Downloaded Error: ~p~n", [Code])
    end,
    Stop = ulitos:timestamp(),
    io:format("Start: ~p; Stop: ~p; Total: ~p;~n", [Start, Stop, Stop - Start]),
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
  
  