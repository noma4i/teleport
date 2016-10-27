-module(teleport_conn).
-author("Benoit Chesneau").

%% API
-export([start_link/3]).

%% supervisor callback
-export([init/1]).

-include("teleport.hrl").

start_link(Sup, Name, Config) ->
  supervisor:start_link({local, Sup}, ?MODULE, [Name, Config]).

init([Name, Config]) ->
  Specs = [lb_spec(Name) | client_specs(Name, Config)],
  {ok, {{one_for_all, 5, 60}, Specs}}.



lb_spec(Name) ->
  #{id => {'teleport_lb', Name},
    start => {teleport_lb, start_link, [Name]},
    restart => temporary,
    shutdown => 5000,
    type => worker,
    modules => [teleport_lb]
  }.

client_specs(Name, Config) ->
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
      Host = maps:get(host, Conf, "localhost"),
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
