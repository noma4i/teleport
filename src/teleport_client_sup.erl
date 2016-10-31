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
  {ok, {{one_for_one, 1, 5}, Specs}}.


%%%===================================================================
%%% Internal functions
%%%===================================================================

client_specs(Name, Config) ->
  case is_map(Config) of
    true ->
      N = maps:get(num_connections, Config, 1),
      [client_spec(teleport_client:client_name(Name, I), Name, Config)
        || I <- lists:seq(1, N)];
    false when is_list(Config) ->
      if
        length(Config) > 0 -> ok;
        true -> error(badarg)
      end,
      group_specs(Config, 0, Name, []);
    false ->
      error(badarg)
  end.

group_specs([Config0 | Rest], I, Name, Acc) ->
  Config1 = case is_list(Config0) of
              true ->
                teleport_uri:parse(Config0);
              false when is_map(Config0) ->
                Config0;
              false ->
                error(badarg)
            end,
  I2 = I + 1,
  Spec = client_spec(
    teleport_client:client_name(Name, I2), Name, Config1
  ),
  group_specs(Rest, I, Name, [Spec | Acc]);
group_specs([], _, _, Acc) ->
  lists:reverse(Acc).

client_spec(Id, Name, Config) ->
  #{id => Id,
    start => {teleport_client, start_link, [Id, Name, Config]},
    restart => permanent,
    shutdown => 2000,
    type => worker,
    modules => [teleport_client]}.

sup_name(Name) ->
  list_to_atom(?MODULE_STRING ++ [$-|atom_to_list(Name)]).
