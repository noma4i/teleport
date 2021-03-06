%% Copyright 2016, Bernard Notarianni
%%
%% Licensed under the Apache License, Version 2.0 (the "License"); you may not
%% use this file except in compliance with the License. You may obtain a copy of
%% the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
%% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
%% License for the specific language governing permissions and limitations under
%% the License.

-module(teleport_SUITE).

-export([all/0,
         end_per_suite/1,
         end_per_testcase/2,
         init_per_suite/1,
         init_per_testcase/2]).

-export([run_on_slave_start_teleport/0]).
-export([run_on_slave_stop_teleport/0]).

-export([
  basic/1,
  start_link/1,
  monitor_link/1,
  monitor_links/1,
  monitor_links2/1,
  channel/1
]).

all() -> [
  basic,
  start_link,
  monitor_link,
  monitor_links,
  monitor_links2,
  channel
].

init_per_suite(Config) ->
  {ok, _} = application:ensure_all_started(teleport),
  {ok, RemoteNode} = start_slave(remote_teleport),
  [{remote, RemoteNode} |Config].

init_per_testcase(_,  Config) ->
  RemoteNode = proplists:get_value(remote, Config),
  {ok, Port} = start_remote_server(RemoteNode),
  [{port, Port} |Config].

end_per_testcase(_, Config) ->
  RemoteNode = proplists:get_value(remote, Config),
  ok = stop_remote_server(RemoteNode),
  proplists:delete(port, Config).

end_per_suite(Config) ->
  ok = stop_slave(remote_teleport),
  Config.

%% ----------

basic([{port, Port}|_]) ->
  true = teleport:connect(test, #{port => Port}),
  false = teleport:connect(test, #{port => Port}),
  3 = teleport:call(test, test_module, add, [1,2]),
  true = (whereis(test) =/= undefined),
  teleport:disconnect(test),
  true = (whereis(test) =:= undefined),
  ok.

start_link([{port, Port}|_]) ->
  {ok, Pid} = teleport_link:start_link(#{port => Port}),
  3 = teleport:call(Pid, test_module, add, [1,2]),
  true = erlang:is_process_alive(Pid),
  _ = shutdown(Pid),
  false = erlang:is_process_alive(Pid),
  ok.

monitor_link([{port, Port}|_]) ->
  teleport:monitor_link(test),
  true = teleport:connect(test, #{port => Port}),
  receive
    {linkup, test} -> ok;
    _ -> error(bad_monitor)
  end,
  teleport:disconnect(test),
  receive
    {linkdown, test} -> ok;
    _ -> error(bad_monitor)
  end,
  teleport:demonitor_link(test),
  true = teleport:connect(test, #{port => Port}),
  receive
    _ -> error(recvd_event)
  after 0 -> ok
  end,
  teleport:disconnect(test),
  timer:sleep(100),
  ok.

monitor_links([{port, Port}|_]) ->
  teleport:monitor_links(true),
  true = teleport:connect(test, #{port => Port}),
  receive
    {linkup, test} -> ok;
    _ -> error(bad_monitor)
  end,
  teleport:disconnect(test),
  receive
    {linkdown, test} -> ok;
    _ -> error(bad_monitor)
  end,
  teleport:monitor_links(false),
  true = teleport:connect(test, #{port => Port}),
  receive
    _ -> error(recvd_event)
  after 0 -> ok
  end,
  teleport:disconnect(test),
  timer:sleep(100),
  ok.

monitor_links2([{port, Port}|_]) ->
  teleport:monitor_links(true),
  true = teleport:connect(test, #{port => Port}),
  timer:sleep(200),
  true = teleport:connect(test2, #{port => Port}),
  timer:sleep(200),
  UpEvents = collect_events([], 2),
  true = (
    UpEvents
      =:=
      [{linkup, test}, {linkup, test2}]
  ),
  teleport:disconnect(test),
  teleport:disconnect(test2),
  DownEvents = collect_events([], 2),
  true = (
    DownEvents
      =:=
      [{linkdown, test}, {linkdown, test2}]
  ),
  teleport:monitor_links(false),
  ok.

channel([{port, Port}|_]) ->
  true = teleport:connect(test, #{port => Port}),
  Channel = teleport:new_channel(test),
  Channel2 = teleport:new_channel(test),
  {welcome, me} = teleport:send_channel_sync(Channel, simple_channel, {hello, me}),
  {welcome, me2} = teleport:send_channel_sync(Channel2, simple_channel, {hello, me2}),
  ok = teleport:register_channel(Channel, simple_channel),
  ok = teleport:register_channel(Channel2, simple_channel),
  ok = teleport:unregister_channel(Channel, simple_channel),
  ok = teleport:unregister_channel(Channel2, simple_channel),
  RegEvents = collect_events([], 4),
  true = (
    length(RegEvents) =:= 4
  ),
  ok = teleport:close_channel(Channel),
  ok = teleport:close_channel(Channel2),
  teleport:disconnect(test),
  ok.


collect_events(Acc, 0) -> lists:reverse(Acc);
collect_events(Acc, N) ->
  receive
    Msg -> collect_events([Msg | Acc], N - 1)
  after 5000 -> error(timeout)
  end.

%% =============================================================================
%% Helpers for creation of remote connections
%% =============================================================================

start_remote_server(HostNode) ->
  {ok_from_slave, Port} = rpc:call(HostNode, ?MODULE, run_on_slave_start_teleport, []),
  {ok, Port}.

stop_remote_server(HostNode) ->
  ok_from_slave = rpc:call(HostNode, ?MODULE, run_on_slave_stop_teleport, []),
  ok.

run_on_slave_start_teleport() ->
  {ok, _Pid} = teleport:start_server(test, []),
  true = teleport_server_sup:server_is_alive(test),
  Port = teleport_server_sup:get_port(test),

  %% start a simple channel
  test_module:start_simple_channel(),

  ct:log("[~p][~p] teleport server started on ~p", [node(), ?MODULE, Port]),
  {ok_from_slave, Port}.

run_on_slave_stop_teleport() ->
  ok = teleport:stop_server(test),
  ct:log("[~p][~p] teleport server stopped", [node(), ?MODULE]),
  ok_from_slave.

start_slave(Node) ->
  {ok, HostNode} = ct_slave:start(Node,
                                  [{kill_if_fail, true}, {monitor_master, true},
                                   {init_timeout, 3000}, {startup_timeout, 3000}]),
  pong = net_adm:ping(HostNode),
  CodePath = filter_rebar_path(code:get_path()),
  true = rpc:call(HostNode, code, set_path, [CodePath]),
  {ok,_} = rpc:call(HostNode, application, ensure_all_started, [teleport]),
  ct:print("\e[32m ---> Node ~p [OK] \e[0m", [HostNode]),
  {ok, HostNode}.

stop_slave(Node) ->
  {ok, _} = ct_slave:stop(Node),
  ok.

%% a hack to filter rebar path
%% see https://github.com/erlang/rebar3/issues/1182
filter_rebar_path(CodePath) ->
  lists:filter(fun(P) ->
                  case string:str(P, "rebar3") of
                    0 -> true;
                    _ -> false
                  end
               end, CodePath).


monitor_child(Pid) ->
  erlang:monitor(process, Pid),
  unlink(Pid),
  receive
    {'EXIT', Pid, Reason} ->
      receive
        {'DOWN', _, process, Pid, _} ->
          {error, Reason}
      end
  after 0 ->
    ok
  end.

shutdown(Pid) ->
  case monitor_child(Pid) of
    ok ->
      exit(Pid, kill),
      receive
        {'DOWN', _MRef, process, Pid, killed} ->
          ok;
        {'DOWN', _MRef, process, Pid, OtherReason} ->
          {error, OtherReason}
      end;
    {error, Reason} ->
      {error, Reason}
  end.