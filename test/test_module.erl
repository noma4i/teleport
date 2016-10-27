-module(test_module).

-export([add/2]).

add(X,Y) ->
  ct:log("[~p][~p] add(~p,~p)", [node(), ?MODULE, X, Y]),
  X+Y.
