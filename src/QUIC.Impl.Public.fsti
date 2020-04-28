module QUIC.Impl.Public
include QUIC.Spec.Public

module LP = LowParse.Low.Base
module U32 = FStar.UInt32
module S = QUIC.Spec.Public
module B = LowStar.Buffer
module U8 = FStar.UInt8
module HS = FStar.HyperStack
module FB = FStar.Bytes
module U64 = FStar.UInt64
module HST = FStar.HyperStack.ST

val validate_header
  (short_dcid_len: short_dcid_len_t)
: Tot (LP.validator (parse_header short_dcid_len))

noeq
type long_header_specifics =
| PInitial:
  (payload_and_pn_length: payload_and_pn_length_t) ->
  (token: B.buffer U8.t) ->
  (token_length: U32.t { let v = U32.v token_length in v == B.length token /\ 0 <= v /\ v <= token_max_len }) ->
  long_header_specifics
| PZeroRTT:
  (payload_and_pn_length: payload_and_pn_length_t) ->
  long_header_specifics
| PHandshake:
  (payload_and_pn_length: payload_and_pn_length_t) ->
  long_header_specifics
| PRetry:
  odcid: B.buffer U8.t ->
  odcil: U32.t { let v = U32.v odcil in v = B.length odcid /\ 0 <= v /\ v <= 20 } ->
  long_header_specifics

noeq
type header =
| PLong:
  (protected_bits: bitfield 4) ->
  (version: U32.t) ->
  dcid: B.buffer U8.t ->
  dcil: U32.t { let v = U32.v dcil in v == B.length dcid /\ 0 <= v /\ v <= 20 } ->
  scid: B.buffer U8.t ->
  scil: U32.t { let v = U32.v scil in v == B.length scid /\ 0 <= v /\ v <= 20 } ->
  (spec: long_header_specifics) ->
  header
| PShort:
  (protected_bits: bitfield 5) ->
  (spin: bool) ->
  cid: B.buffer U8.t ->
  cid_len: U32.t{
    let l = U32.v cid_len in
    l == B.length cid /\
    0 <= l /\ l <= 20
  } ->
  header

let header_live (h: header) (m: HS.mem) : GTot Type0 =
  match h with
  | PShort protected_bits spin cid cid_len ->
    B.live m cid
  | PLong protected_bits version dcid dcil scid scil spec ->
    B.live m dcid /\ B.live m scid /\
    begin match spec with
    | PInitial payload_and_pn_length token token_length ->
      B.live m token
    | PRetry odcid odcil ->
      B.live m odcid
    | _ -> True
    end

let header_footprint (h: header) : GTot B.loc =
  match h with
  | PShort protected_bits spin cid cid_len ->
    B.loc_buffer cid
  | PLong protected_bits version dcid dcil scid scil spec ->
    B.loc_buffer dcid `B.loc_union` B.loc_buffer scid `B.loc_union`
    begin match spec with
    | PInitial payload_and_pn_length token token_length ->
      B.loc_buffer token
    | PRetry odcid odcil ->
      B.loc_buffer odcid
    | _ -> B.loc_none
    end

let header_live_loc_not_unused_in_footprint (h: header) (m: HS.mem) : Lemma
  (requires (header_live h m))
  (ensures (B.loc_not_unused_in m `B.loc_includes` header_footprint h))
= ()

let g_header (h: header) (m: HS.mem) : GTot S.header =
  match h with
  | PShort protected_bits spin cid cid_len ->
    S.PShort protected_bits spin (FB.hide (B.as_seq m cid))
  | PLong protected_bits version dcid dcil scid scil spec ->
    S.PLong protected_bits version (FB.hide (B.as_seq m dcid)) (FB.hide (B.as_seq m scid))
    begin match spec with
    | PInitial payload_and_pn_length token token_length ->
      S.PInitial (FB.hide (B.as_seq m token)) payload_and_pn_length 
    | PRetry odcid odcil ->
      S.PRetry (FB.hide (B.as_seq m odcid))
    | PHandshake payload_and_pn_length -> S.PHandshake payload_and_pn_length
    | PZeroRTT payload_and_pn_length -> S.PZeroRTT payload_and_pn_length    
    end

let frame_header_live
  (h: header)
  (l: B.loc)
  (m1 m2: HS.mem)
: Lemma
  (requires (
    header_live h m1 /\
    B.modifies l m1 m2 /\
    B.loc_disjoint l (header_footprint h)
  ))
  (ensures (header_live h m2))
= ()

let frame_header
  (h: header)
  (l: B.loc)
  (m1 m2: HS.mem)
: Lemma
  (requires (
    header_live h m1 /\
    B.modifies l m1 m2 /\
    B.loc_disjoint l (header_footprint h)
  ))
  (ensures (header_live h m2 /\ g_header h m2 == g_header h m1))
= ()


val read_header
  (packet: B.buffer U8.t)
  (packet_len: U32.t { let v = U32.v packet_len in v == B.length packet })
  (cid_len: U32.t { U32.v cid_len <= 20 } )
: HST.Stack (option (header & U32.t))
  (requires (fun h ->
    B.live h packet
  ))
  (ensures (fun h res h' ->
    B.modifies B.loc_none h h' /\
    begin
      match LP.parse (parse_header cid_len) (B.as_seq h packet), res with
      | None, None -> True
      | Some (x, len), Some (x', len') ->
        header_live x' h' /\
        len <= B.length packet /\
        B.loc_buffer (B.gsub packet 0ul (U32.uint_to_t len)) `B.loc_includes` header_footprint x' /\
        g_header x' h' == x /\
        U32.v len' == len
      | _ -> False
    end
  ))