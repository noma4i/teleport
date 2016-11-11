-module(test_module).

-export([
  add/2,
  start_simple_channel/0
]).

-export([simple_channel/0]).

add(X,Y) ->
  ct:log("[~p][~p] add(~p,~p)", [node(), ?MODULE, X, Y]),
  X+Y.

start_simple_channel() ->
  spawn(?MODULE, simple_channel, []).

simple_channel() ->
  register(simple_channel, self()),
  simple_channel_loop().

simple_channel_loop() ->
  receive
    {'$channel_req', _ChannelId, Pid, {hello, Name}} ->
      Pid ! {welcome, Name},
      simple_channel_loop();
    {'$channel_register', _ChannelId, Pid}=Msg ->
      Pid ! Msg,
      simple_channel_loop();
    {'$channel_unregister', _ChannelId, Pid}=Msg ->
      Pid ! Msg,
      simple_channel_loop()
  end.
