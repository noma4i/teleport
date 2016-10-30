%% Copyright (c) 2016 Contributors as noted in the AUTHORS file
%%
%% This file is part teleport
%%
%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at http://mozilla.org/MPL/2.0/.

-module(teleport_client_sup).
-author("Benoit Chesneau").

-behaviour(supervisor).
%% API
-export([start_link/2]).
%% Supervisor callbacks
-export([init/1]).


-include("teleport.hrl").

%%%===================================================================
%%% API functions
%%%===================================================================

-spec start_link(atom(), any()) -> {ok, pid()} | {error, term()}.
start_link(Name, Config) ->
  supervisor:start_link({local, sup_name(Name) }, ?MODULE, [Name, Config]).
%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

-spec init(any()) ->
  {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([Name, Config]) ->
  Specs = client_specs(Name, Config),
  {ok, {{one_for_one, 5, 60}, Specs}}.


%%%===================================================================
%%% Internal functions
%%%===================================================================

client_specs(Name, Config) ->
  HostName = inet:gethostname(),
  Configs = case is_map(Config) of
              true -> [Config];
              false when is_list(Config) ->
                if
                  length(Config) > 0 -> ok;
                  true -> error(badarg)
                end,
                Config;
              false -> error(badarg)
            end,

  ClientSpecs = lists:map(
    fun(Conf) ->
      NumClients = maps:get(num_connections, Conf, 1),
      Host = maps:get(host, Conf, HostName),
      Port = maps:get(port, Conf, ?DEFAULT_PORT),
      lists:map(
        fun(I) ->
          client_spec({'teleport_client', Name, {Host, Port}, I}, Name, Config)
        end,lists:seq(1, NumClients))
    end, Configs),
  lists:flatten(ClientSpecs).

client_spec(Id, Name, Config) ->
  #{id => Id,
    start => {teleport_client, start_link, [Name, Config]},
    restart => permanent,
    shutdown => 2000,
    type => worker,
    modules => [teleport_client]}.

sup_name(Name) ->
  list_to_atom(?MODULE_STRING ++ [$-|atom_to_list(Name)]).
