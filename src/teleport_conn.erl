-module(teleport_conn).
-author("Benoit Chesneau").

%% API
-export([start_link/3]).

%% supervisor callback
-export([init/1]).


start_link(Sup, Name, Config) ->
  supervisor:start_link({local, Sup}, ?MODULE, [Name, Config]).

init([Name, Config]) ->
  LbSpec =
    #{id => {'teleport_lb', Name},
      start => {teleport_lb, start_link, [Name]},
      restart => permanent,
      shutdown => 2000,
      type => worker,
      modules => [teleport_lb]
    },

  ClientSup =
    #{id => {'teleport_client_sup', Name},
      start => {teleport_client_sup, start_link, [Name, Config]},
      restart => permanent,
      shutdown => 2000,
      type => supervisor,
      modules => [teleport_client_sup]
    },

  {ok, {{one_for_all, 5, 60}, [LbSpec, ClientSup]}}.
