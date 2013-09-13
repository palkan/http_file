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

main(["bench", Url, Thrds,  Ext,NumS]) ->
  
  ibrowse:start(),
  
  Threads = list_to_integer(Thrds), 

  Num = list_to_integer(NumS),
  
  List = [Threads],
 
  run(List,Num,Num,[],Url,Ext).


run([],_,_,Res,_,_) ->
  [io:format("threads: ~p; time: ~p~n",[S,T]) || {S,T} <- Res];


run([H|Tail],Num,1,Res,Url,Ext) ->
	Start = ulitos:timestamp(),
	Options = if H == 0 
			-> [{cache_file,"01."++Ext},{chunked,false}];
			true -> [{cache_file,integer_to_list(H)++"1."++Ext}]
		end,
	io:format("running: threads ~p, count: 1 ...~n",[H]),
	case http_file:download(Url,Options) of
                        {ok,_Data} -> Stop = ulitos:timestamp(),
					io:format("done: threads ~p, count: 1; time ~p~n",[H,Stop - Start]),
				     run(Tail,Num,Num,[{H,Stop-Start}|Res],Url,Ext);
                        {error, Code} -> io:format("File Error: ~p~n", [Code])
 	end;

run([H|Tail],Num,Count,Res,Url,Ext) ->
	Start = ulitos:timestamp(),
	Options = if H == 0 ->
			[{cache_file,"0"++integer_to_list(Count)++"."++Ext},{chunked,false}];
			true -> [{cache_file,integer_to_list(H)++integer_to_list(Count)++"."++Ext}]
		end,
	io:format("running: threads ~p; count ~p...~n",[H,Count]),
	case http_file:download(Url,Options) of
			{ok,_Data} -> Stop = ulitos:timestamp(),
					io:format("done: threads ~p, count ~p; time ~p~n", [H,Count,Stop-Start]),
				     run([H|Tail],Num,Count-1,[{H,Stop-Start}|Res],Url,Ext);
			{error,Code} -> io:format("error: ~p",[Code])
		end.



wait(0) ->
  ok;

wait(N) ->
  receive
    tick -> wait(N - 1)
  end.
  
  
