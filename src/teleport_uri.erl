%% Copyright (c) 2016 Contributors as noted in the AUTHORS file
%%
%% This file is part teleport
%%
%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at http://mozilla.org/MPL/2.0/.

-module(teleport_uri).
-author("Benoit Chesneau").

%% API
-export([
  parse/1,
  config_from_uri/1
]).

-include("teleport.hrl").

parse(Uri) ->
  case re:split(Uri, "://", [{return, list}]) of
    [Proto, Rest] ->
      parse1(Rest,
        #{proto => Proto,
          path => "/"});
    _ -> error(bad_uri)
  end.

parse1(S, Parsed) ->
  case re:split(S, "/", [{return, list}]) of
    [Addr] ->
      case re:split(S, "\\?", [{return, list}]) of
        [Addr] -> parse_addr(Addr, Parsed);
        [Addr1, Rest] ->
          Parsed1 = parse_query(Rest, Parsed),
          parse_addr(Addr1, Parsed1)
      end;
    [Addr, Path] ->
      Parsed1 = parse_path(Path, Parsed),
      parse_addr(Addr, Parsed1)
  end.

parse_path(S, Parsed) ->
  case re:split(S, "\\?", [{return, list}]) of
    [Path] -> Parsed#{ qs => "", path => [$/ |Path]};
    [Path, Query] ->
      {Query1, _Fragment} = parse_fragment(Query),
      parse_query(Query1, Parsed#{ qs => Query, path => [$/ |Path]})
  end.

parse_fragment(S) ->
  case re:split(S, "#", [{return, list}]) of
    [_S] -> {S, ""};
    [S, F] -> {S, F}
  end.

parse_query("", Parsed) -> Parsed;
parse_query(S, Parsed) ->
  Tokens = string:tokens(S, "&"),
  Qs = [case re:split(Token, "=", [trim, {return, list}]) of
          [T] ->
            {list_to_atom(http_uri:decode(T)), true};
          [Name, Value] ->
            {list_to_atom(http_uri:decode(Name)), dec(http_uri:decode(Value))}
        end || Token <- Tokens],
  maps:merge(Parsed, maps:from_list(Qs)).


parse_addr(Addr, Parsed) ->
  case re:split(Addr, "@", [trim, {return, list}]) of
    [Addr] ->
      parse_addr_1(Addr, Parsed#{ user => nil});
    [User, Addr2] ->
      parse_addr_1(Addr2, Parsed#{ user => User})
  end.

parse_addr_1([$[ | Rest], Parsed) ->
  case re:split(Rest, "]", [{return, list}]) of
    [Host, []] ->
      Port = ?DEFAULT_PORT,
      Parsed#{host => Host, port => Port};
    [Host, [$: | PortString]] ->
      Port = list_to_integer(PortString),
      Parsed#{host => Host, port => Port};
    _ ->
      parse_addr_1(Rest, Parsed)
  
  end;
parse_addr_1(Netloc, Parsed) ->
  case re:split(Netloc, ":", [{return, list}]) of
    [Host] ->
      Port = ?DEFAULT_PORT,
      Parsed#{host => Host, port => Port};
    [Host, PortString] ->
      Port = list_to_integer(PortString),
      Parsed#{host => Host, port => Port}
  end.

dec("true") -> true;
dec("false") -> false;
dec(_) -> error(badarg).

config_from_uri(Uri) ->
  #{ proto := Proto } = Parsed = parse(Uri),
  case Proto of
    "link" -> {ok, Parsed#{ transport => tcp }};
    "slink" -> {ok, Parsed#{ transport => ssl }};
    _ ->
      Protos = application:get_env(teleport, protocols, []),
      case proplists:get_value(Proto, Protos) of
        undefined -> unsuported_protocol;
        Mod ->
          Mod:setup(Parsed)
      end
  end.
