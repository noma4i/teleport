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

-export([basic/1]).

all() -> [basic].

init_per_suite(Config) ->
  {ok, _} = application:ensure_all_started(teleport),
  Config.

init_per_testcase(_, Config) ->
  Config.

end_per_testcase(_, Config) ->
  Config.

end_per_suite(Config) ->
  Config.

%% ----------

basic(_Config) ->
  {ok, RemoteNode} = start_slave(remote_teleport),
  ok = start_remote_server(RemoteNode),

  true = teleport:connect(test, #{}),

  3 = teleport:call(test, test_module, add, [1,2]),

  ok = stop_remote_server(RemoteNode),
  ok = stop_slave(remote_teleport),
  ok.

%% =============================================================================
%% Helpers for creation of remote connections
%% =============================================================================

start_remote_server(HostNode) ->
  ok_from_slave = rpc:call(HostNode, ?MODULE, run_on_slave_start_teleport, []),
  ok.

stop_remote_server(HostNode) ->
  ok_from_slave = rpc:call(HostNode, ?MODULE, run_on_slave_stop_teleport, []),
  ok.

run_on_slave_start_teleport() ->
  {ok, _Pid} = teleport:start_server(test, []),
  ct:log("[~p][~p] teleport server started", [node(), ?MODULE]),
  ok_from_slave.

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
