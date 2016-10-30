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
  parse_transport/1,
  get_transport/1,
  to_transport/1
]).

-include("teleport.hrl").

parse(Uri) ->
  case re:split(Uri, "://", [{return, list}]) of
    [Scheme, Rest] ->
      [_Prefix, Transport] = re:split(Scheme, "\\.", [{return, list}]),
      parse1(Rest,
        #{scheme => Scheme,
          transport => list_to_atom(Transport),
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
      erlang:error(bad_uri);
    [Name, Addr2] ->
      parse_addr_1(Addr2, Parsed#{ name => teleport_lib:to_atom(Name)})
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

%% TODO: add a better way to make transports pluggable
parse_transport(#{ transport := ssl}) -> ranch_ssl;
parse_transport(#{ transport := tcp}) -> ranch_tcp;
parse_transport(#{ transport := Else}) -> Else;
parse_transport(_) -> ranch_tcp.

get_transport(tcp) -> ranch_tcp;
get_transport(ssl) -> ranch_ssl;
get_transport(Mod) -> Mod.

to_transport(ranch_tcp) -> tcp;
to_transport(ranch_ssl) -> ssl;
to_transport(Mod) -> Mod.
