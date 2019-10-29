module QUIC.Impl

// This MUST be kept in sync with QUIC.Impl.fsti...
module G = FStar.Ghost
module B = LowStar.Buffer
module IB = LowStar.ImmutableBuffer
module S = FStar.Seq
module HS = FStar.HyperStack
module ST = FStar.HyperStack.ST


module U64 = FStar.UInt64
module U32 = FStar.UInt32
module U8 = FStar.UInt8

open FStar.HyperStack
open FStar.HyperStack.ST

open EverCrypt.Helpers
open EverCrypt.Error

#set-options "--max_fuel 0 --max_ifuel 0"
// ... up to here!

module Cipher = EverCrypt.Cipher
module AEAD = EverCrypt.AEAD
module HKDF = EverCrypt.HKDF
module CTR = EverCrypt.CTR

friend QUIC.Spec

open LowStar.BufferOps

inline_for_extraction noextract
let as_cipher_alg (a: QUIC.Spec.ea): a:Spec.Agile.Cipher.cipher_alg {
  Spec.Agile.Cipher.(a == AES128 \/ a == AES256 \/ a == CHACHA20)
} =
  Spec.Agile.AEAD.cipher_alg_of_supported_alg a

/// https://tools.ietf.org/html/draft-ietf-quic-tls-23#section-5
///
/// We perform the three key derivations (AEAD key; AEAD iv; header protection
/// key) when ``create`` is called. We thus store the original traffic secret
/// only ghostly.
///
/// We retain the AEAD state, in order to perform the packet payload encryption.
///
/// We retain the Cipher state, in order to compute the mask for header protection.
noeq
type state_s (i: index) =
  | State:
      the_hash_alg:hash_alg { the_hash_alg == i.hash_alg } ->
      the_aead_alg:aead_alg { the_aead_alg == i.aead_alg } ->
      traffic_secret:G.erased (Spec.Hash.Definitions.bytes_hash the_hash_alg) ->
      initial_pn:G.erased QUIC.Spec.nat62 ->
      aead_state:EverCrypt.AEAD.state the_aead_alg ->
      iv:EverCrypt.AEAD.iv_p the_aead_alg ->
      hp_key:B.buffer U8.t { B.length hp_key = QUIC.Spec.ae_keysize the_aead_alg } ->
      pn:B.pointer u62 ->
      ctr_state:CTR.state (as_cipher_alg the_aead_alg) ->
      state_s i

let footprint_s #i h s =
  let open LowStar.Buffer in
  AEAD.footprint h (State?.aead_state s) `loc_union`
  CTR.footprint h (State?.ctr_state s) `loc_union`
  loc_buffer (State?.iv s) `loc_union`
  loc_buffer (State?.hp_key s) `loc_union`
  loc_buffer (State?.pn s)

let g_traffic_secret #i s =
  // Automatic reveal insertion doesn't work here
  G.reveal (State?.traffic_secret s)

let g_initial_packet_number #i s =
  // New style: automatic insertion of reveal
  State?.initial_pn s

let invariant_s #i h s =
  let open QUIC.Spec in
  let State hash_alg aead_alg traffic_secret initial_pn aead_state iv hp_key pn ctr_state =
    s
  in
  hash_is_keysized s; (
  AEAD.invariant h aead_state /\
  not (B.g_is_null aead_state) /\
  CTR.invariant h ctr_state /\
  not (B.g_is_null ctr_state) /\
  B.(all_live h [ buf iv; buf hp_key; buf pn ])  /\
  B.(all_disjoint [ CTR.footprint h ctr_state;
    AEAD.footprint h aead_state; loc_buffer iv; loc_buffer hp_key; loc_buffer pn ]) /\
  // JP: automatic insertion of reveal does not work here
  G.reveal initial_pn <= U64.v (B.deref h pn) /\
  AEAD.as_kv (B.deref h aead_state) ==
    derive_secret i.hash_alg (G.reveal traffic_secret) label_key (Spec.Agile.AEAD.key_length aead_alg) /\
  B.as_seq h iv ==
    derive_secret i.hash_alg (G.reveal traffic_secret) label_iv 12 /\
  B.as_seq h hp_key ==
    derive_secret i.hash_alg (G.reveal traffic_secret) label_hp (QUIC.Spec.ae_keysize aead_alg)
  )

let invariant_loc_in_footprint #_ _ _ = ()

let g_packet_number #i s h =
  U64.v (B.deref h (State?.pn s))

let frame_invariant #i l s h0 h1 =
  AEAD.frame_invariant l (State?.aead_state (B.deref h0 s)) h0 h1;
  CTR.frame_invariant l (State?.ctr_state (B.deref h0 s)) h0 h1

let aead_alg_of_state #i s =
  let State _ the_aead_alg _ _ _ _ _ _ _ = !*s in
  the_aead_alg

let hash_alg_of_state #i s =
  let State the_hash_alg _ _ _ _ _ _ _ _ = !*s in
  the_hash_alg

let packet_number_of_state #i s =
  let State _ _ _ _ _ _ _ pn _ = !*s in
  !*pn

#push-options "--max_ifuel 1 --initial_ifuel 1"
/// One ifuel for inverting on the hash algorithm for computing bounds (the
/// various calls to assert_norm should help ensure this proof goes through
/// reliably). Note that I'm breaking from the usual convention where lengths
/// are UInt32's, mostly to avoid trouble reasoning with modulo when casting
/// from UInt32 to UInt8 to write the label for the key derivation. This could
/// be fixed later.
val derive_secret: a: QUIC.Spec.ha ->
  dst:B.buffer U8.t ->
  dst_len: U8.t { B.length dst = U8.v dst_len /\ U8.v dst_len <= 255 } ->
  secret:B.buffer U8.t { B.length secret = Spec.Hash.Definitions.hash_length a } ->
  label:IB.ibuffer U8.t ->
  label_len:U8.t { IB.length label = U8.v label_len /\ U8.v label_len <= 244 } ->
  Stack unit
    (requires fun h0 ->
      B.(all_live h0 [ buf secret; buf label; buf dst ]) /\
      B.disjoint dst secret)
    (ensures fun h0 _ h1 ->
      assert_norm (255 < pow2 61);
      assert_norm (pow2 61 < pow2 125);
      B.(modifies (loc_buffer dst) h0 h1) /\
      B.as_seq h1 dst == QUIC.Spec.derive_secret a (B.as_seq h0 secret)
        (IB.as_seq h0 label) (U8.v dst_len))
#pop-options

let prefix = LowStar.ImmutableBuffer.igcmalloc_of_list HS.root QUIC.Spec.prefix_l

let lemma_five_cuts (s: S.seq U8.t) (i1 i2 i3 i4 i5: nat) (s0 s1 s2 s3 s4 s5: S.seq U8.t): Lemma
  (requires (
    i1 <= S.length s /\
    i2 <= S.length s /\
    i3 <= S.length s /\
    i4 <= S.length s /\
    i5 <= S.length s /\
    i1 <= i2 /\
    i2 <= i3 /\
    i3 <= i4 /\
    i4 <= i5 /\
    s0 `Seq.equal` S.slice s 0 i1 /\
    s1 `Seq.equal` S.slice s i1 i2 /\
    s2 `Seq.equal` S.slice s i2 i3 /\
    s3 `Seq.equal` S.slice s i3 i4 /\
    s4 `Seq.equal` S.slice s i4 i5 /\
    s5 `Seq.equal` S.slice s i5 (S.length s)))
  (ensures (
    let open S in
    s `equal` (s0 @| s1 @| s2 @| s3 @| s4 @| s5)))
=
  ()

let hash_is_keysized_ (a: QUIC.Spec.ha): Lemma
  (ensures (QUIC.Spec.keysized a (Spec.Hash.Definitions.hash_length a)))
=
  assert_norm (512 < pow2 61);
  assert_norm (512 < pow2 125)

#set-options "--z3rlimit 100"
let derive_secret a dst dst_len secret label label_len =
  LowStar.ImmutableBuffer.recall prefix;
  LowStar.ImmutableBuffer.recall_contents prefix QUIC.Spec.prefix;
  (**) let h0 = ST.get () in

  push_frame ();
  (**) let h1 = ST.get () in

  let label_len32 = FStar.Int.Cast.uint8_to_uint32 label_len in
  let dst_len32 = FStar.Int.Cast.uint8_to_uint32 dst_len in
  let info_len = U32.(1ul +^ 1ul +^ 1ul +^ 11ul +^ label_len32 +^ 1ul) in
  let info = B.alloca 0uy info_len in

  // JP: best way to reason about this sort of code is to slice the buffer very thinly
  let info_z = B.sub info 0ul 1ul in
  let info_lb = B.sub info 1ul 1ul in
  let info_llen = B.sub info 2ul 1ul in
  let info_prefix = B.sub info 3ul 11ul in
  let info_label = B.sub info 14ul label_len32 in
  let info_z' = B.sub info (14ul `U32.add` label_len32) 1ul in
  (**) assert (14ul `U32.add` label_len32 `U32.add` 1ul = B.len info);
  (**) assert B.(all_disjoint [ loc_buffer info_z; loc_buffer info_lb; loc_buffer info_llen;
  (**)   loc_buffer info_prefix; loc_buffer info_label; loc_buffer info_z' ]);

  info_lb.(0ul) <- dst_len;
  info_llen.(0ul) <- U8.(label_len +^ 11uy);
  B.blit prefix 0ul info_prefix 0ul 11ul;
  B.blit label 0ul info_label 0ul label_len32;

  (**) let h2 = ST.get () in
  (**) assert (
  (**)   let z = S.create 1 0uy in
  (**)   let lb = S.create 1 dst_len in // len <= 255
  (**)   let llen = S.create 1 (U8.uint_to_t (11 + Seq.length (B.as_seq h0 label))) in
  (**)   let info = B.as_seq h2 info in
  (**)   B.as_seq h2 info_z `Seq.equal` z /\
  (**)   B.as_seq h2 info_lb `Seq.equal` lb /\
  (**)   B.as_seq h2 info_llen `Seq.equal` llen /\
  (**)   B.as_seq h2 info_prefix `Seq.equal` QUIC.Spec.prefix /\
  (**)   B.as_seq h2 info_label `Seq.equal` (B.as_seq h0 label) /\
  (**)   B.as_seq h2 info_z' `Seq.equal` z
  (**) );
  (**) (
  (**)   let z = S.create 1 0uy in
  (**)   let lb = S.create 1 dst_len in // len <= 255
  (**)   let llen = S.create 1 (U8.uint_to_t (11 + Seq.length (B.as_seq h0 label))) in
  (**)   let info = B.as_seq h2 info in
  (**)   lemma_five_cuts info 1 2 3 14 (14 + U8.v label_len)
  (**)     z lb llen QUIC.Spec.prefix (B.as_seq h0 label) z
  (**) );
  (**) hash_is_keysized_ a;
  HKDF.expand a dst secret (Hacl.Hash.Definitions.hash_len a) info info_len dst_len32;
  (**) let h3 = ST.get () in
  pop_frame ();
  (**) let h4 = ST.get () in
  (**) B.modifies_fresh_frame_popped h0 h1 (B.loc_buffer dst) h3 h4;
  (**) assert (ST.equal_domains h0 h4)

let key_len (a: QUIC.Spec.ea): x:U8.t { U8.v x = Spec.Agile.AEAD.key_length a } =
  let open Spec.Agile.AEAD in
  match a with
  | AES128_GCM -> 16uy
  | AES256_GCM -> 32uy
  | CHACHA20_POLY1305 -> 32uy

let key_len32 a = FStar.Int.Cast.uint8_to_uint32 (key_len a)

let label_key = LowStar.ImmutableBuffer.igcmalloc_of_list HS.root QUIC.Spec.label_key_l
let label_iv = LowStar.ImmutableBuffer.igcmalloc_of_list HS.root QUIC.Spec.label_iv_l
let label_hp = LowStar.ImmutableBuffer.igcmalloc_of_list HS.root QUIC.Spec.label_hp_l

// JP: this proof currently takes 12 minutes. It could conceivably be improved.
#push-options "--z3rlimit 1000 --query_stats"
let create_in i r dst initial_pn traffic_secret =
  LowStar.ImmutableBuffer.recall label_key;
  LowStar.ImmutableBuffer.recall_contents label_key QUIC.Spec.label_key;
  LowStar.ImmutableBuffer.recall label_iv;
  LowStar.ImmutableBuffer.recall_contents label_iv QUIC.Spec.label_iv;
  LowStar.ImmutableBuffer.recall label_hp;
  LowStar.ImmutableBuffer.recall_contents label_hp QUIC.Spec.label_hp;
  (**) let h0 = ST.get () in
  [@inline_let]
  let e_traffic_secret: G.erased (Spec.Hash.Definitions.bytes_hash i.hash_alg) =
    G.hide (B.as_seq h0 traffic_secret)
  in
  [@inline_let]
  let e_initial_pn: G.erased QUIC.Spec.nat62 = G.hide (U64.v initial_pn) in
  [@inline_let]
  let hash_alg = i.hash_alg in
  [@inline_let]
  let aead_alg = i.aead_alg in

  push_frame ();
  (**) let h1 = ST.get () in

  let aead_key = B.alloca 0uy (key_len32 aead_alg) in
  derive_secret hash_alg aead_key (key_len aead_alg) traffic_secret label_key 3uy;

  (**) let h2 = ST.get () in
  (**) B.(modifies_loc_includes (loc_unused_in h1) h1 h2 (loc_buffer aead_key));

  let aead_state: B.pointer (B.pointer_or_null (AEAD.state_s aead_alg)) =
    B.alloca B.null 1ul
  in
  let ret = AEAD.create_in #aead_alg r aead_state aead_key in

  let ctr_state: B.pointer (B.pointer_or_null (CTR.state_s (as_cipher_alg aead_alg))) =
    B.alloca (B.null #(CTR.state_s (as_cipher_alg aead_alg))) 1ul
  in
  let dummy_iv = B.alloca 0uy 12ul in
  let ret' = CTR.create_in (as_cipher_alg aead_alg) r ctr_state aead_key dummy_iv 12ul 0ul in

  (**) let h3 = ST.get () in
  (**) B.(modifies_loc_includes (loc_unused_in h1) h2 h3
    (loc_buffer ctr_state `loc_union` loc_buffer aead_state));
  (**) B.(modifies_trans (loc_unused_in h1) h1 h2 (loc_unused_in h1) h3);

  match ret with
  | UnsupportedAlgorithm ->
      pop_frame ();
      UnsupportedAlgorithm

  | Success ->

      match ret' with
      | UnsupportedAlgorithm ->
          pop_frame ();
          UnsupportedAlgorithm

      | Success ->
      // JP: there is something difficult to prove here... confused.
      let aead_state: AEAD.state aead_alg = !*aead_state in
      (**) assert (AEAD.invariant h3 aead_state);

      let ctr_state: CTR.state (as_cipher_alg aead_alg) = !*ctr_state in
      (**) assert (CTR.invariant h3 ctr_state);

      let iv = B.malloc r 0uy 12ul in
      (**) assert_norm FStar.Mul.(8 * 12 <= pow2 64 - 1);
      (**) let h4 = ST.get () in
      (**) B.(modifies_loc_includes (loc_buffer dst) h3 h4 loc_none);

      let hp_key = B.malloc r 0uy (key_len32 aead_alg) in
      (**) let h5 = ST.get () in
      (**) B.(modifies_loc_includes (loc_buffer dst) h4 h5 loc_none);

      let pn = B.malloc r initial_pn 1ul in
      (**) let h6 = ST.get () in
      (**) B.(modifies_loc_includes (loc_buffer dst) h5 h6 loc_none);

      (**) assert (B.length hp_key = QUIC.Spec.ae_keysize aead_alg);
      let s: state_s i = State #i
        hash_alg aead_alg e_traffic_secret e_initial_pn
        aead_state iv hp_key pn ctr_state
      in
      let s:B.pointer_or_null (state_s i) = B.malloc r s 1ul in
      (**) let h7 = ST.get () in
      (**) B.(modifies_loc_includes (loc_buffer dst) h6 h7 loc_none);

      derive_secret hash_alg iv 12uy traffic_secret label_iv 2uy;
      (**) let h8 = ST.get () in
      (**) B.(modifies_loc_includes (loc_unused_in h1) h7 h8 (loc_buffer iv));

      derive_secret hash_alg hp_key (key_len aead_alg) traffic_secret label_hp 2uy;
      (**) let h9 = ST.get () in
      (**) B.(modifies_loc_includes (loc_unused_in h1) h8 h9 (loc_buffer hp_key));
      (**) B.(modifies_trans (loc_unused_in h1) h7 h8 (loc_unused_in h1) h9);

      dst *= s;

      (**) let h10 = ST.get () in
      (**) B.(modifies_trans (loc_unused_in h1) h7 h9 (loc_buffer dst) h10);
      (**) B.(modifies_trans (loc_unused_in h1) h1 h3 (loc_buffer dst) h7);
      (**) B.(modifies_trans (loc_buffer dst) h3 h7
      (**)   (loc_unused_in h1 `loc_union` loc_buffer dst) h10);
      (**) B.(modifies_only_not_unused_in (loc_buffer dst) h1 h10);
      (**) B.(modifies_only_not_unused_in (loc_buffer dst) h3 h10);
      (**) B.fresh_frame_modifies h0 h1;
      (**) B.(modifies_trans loc_none h0 h1 (loc_buffer dst) h10);

      // TODO: everything goes through well up to here; and we know:
      //   B.modifies (loc_buffer dst) h0 h10
      // NOTE: how to conclude efficiently the same thing with h11?
      pop_frame ();
      (**) let h11 = ST.get () in
      (**) assert (AEAD.invariant #aead_alg h11 aead_state);
      (**) assert (CTR.invariant #(as_cipher_alg aead_alg) h11 ctr_state);
      (**) B.popped_modifies h10 h11;
      (**) assert B.(modifies (loc_buffer dst) h0 h11);
      (**) assert (ST.equal_stack_domains h0 h11);

      Success
#pop-options

let lemma_slice s (i: nat { i <= S.length s }): Lemma
  (ensures (s `S.equal` S.append (S.slice s 0 i) (S.slice s i (S.length s))))
=
  ()

#push-options "--max_fuel 1 --z3rlimit 100"
let rec pointwise_upd (#a: eqtype) f b1 b2 i pos (x: a): Lemma
  (requires (S.length b2 + pos <= S.length b1 /\ i < pos))
  (ensures (S.upd (QUIC.Spec.pointwise_op f b1 b2 pos) i x `S.equal`
    QUIC.Spec.pointwise_op f (S.upd b1 i x) b2 pos))
  (decreases (S.length b2))
=
  calc (S.equal) {
    QUIC.Spec.pointwise_op f (S.upd b1 i x) b2 pos;
  (S.equal) { lemma_slice (S.upd b1 i x) (i + 1) }
    QUIC.Spec.pointwise_op f
      S.(slice (S.upd b1 i x) 0 (i + 1) @| S.slice (S.upd b1 i x) (i + 1) (S.length b1))
      b2 pos;
  (S.equal) { }
    QUIC.Spec.pointwise_op f
      S.(slice (S.upd b1 i x) 0 (i + 1) @| S.slice b1 (i + 1) (S.length b1))
      b2 pos;
  (S.equal) {
    QUIC.Spec.pointwise_op_suff f
      (S.slice (S.upd b1 i x) 0 (i + 1))
      (S.slice b1 (i + 1) (S.length b1)) b2 pos
  }
    S.slice (S.upd b1 i x) 0 (i + 1) `S.append`
    QUIC.Spec.pointwise_op f
      (S.slice b1 (i + 1) (S.length b1))
      b2 (pos - (i + 1));
  (S.equal) { }
    S.upd (S.slice b1 0 (i + 1)) i x `S.append`
    QUIC.Spec.pointwise_op f
      (S.slice b1 (i + 1) (S.length b1))
      b2 (pos - (i + 1));
  (S.equal) { }
    S.upd (S.slice b1 0 (i + 1) `S.append`
    QUIC.Spec.pointwise_op f
      (S.slice b1 (i + 1) (S.length b1))
      b2 (pos - (i + 1))
    ) i x;
  (S.equal) {
    QUIC.Spec.pointwise_op_suff f
      (S.slice b1 0 (i + 1))
      (S.slice b1 (i + 1) (S.length b1)) b2 pos
  }
    S.upd (
      QUIC.Spec.pointwise_op f
      (S.slice b1 0 (i + 1) `S.append` S.slice b1 (i + 1) (S.length b1))
      b2 pos
    ) i x;
  (S.equal) { lemma_slice b1 (i + 1) }
    S.upd (QUIC.Spec.pointwise_op f b1 b2 pos) i x;
  }

let rec pointwise_seq_map2 (#a: eqtype) (f: a -> a -> a) (s1 s2: S.seq a) (i: nat): Lemma
  (requires (
    let l = S.length s1 in
    S.length s2 = l - i /\ i <= S.length s1))
  (ensures (
    let l = S.length s1 in
    Spec.Loops.seq_map2 f (S.slice s1 i l) s2 `S.equal`
    S.slice (QUIC.Spec.pointwise_op f s1 s2 i) i l))
  (decreases (S.length s2))
=
  if S.length s2 = 0 then
    ()
  else
    let l = S.length s1 in
    calc (S.equal) {
      Spec.Loops.seq_map2 f (S.slice s1 i l) s2;
    (S.equal) {}
      S.cons (f (S.head (S.slice s1 i l)) (S.head s2))
        (Spec.Loops.seq_map2 f (S.tail (S.slice s1 i l)) (S.tail s2));
    (S.equal) {}
      S.cons (f (S.head (S.slice s1 i l)) (S.head s2))
        (Spec.Loops.seq_map2 f (S.slice s1 (i + 1) l) (S.tail s2));
    (S.equal) { pointwise_seq_map2 f s1 (S.slice s2 1 (S.length s2)) (i + 1) }
      S.cons (f (S.head (S.slice s1 i l)) (S.head s2))
        (S.slice (QUIC.Spec.pointwise_op f s1 (S.tail s2) (i + 1)) (i + 1) l);
    (S.equal) { }
      S.slice (
        S.upd (QUIC.Spec.pointwise_op f s1 (S.tail s2) (i + 1))
          i
          (f (S.head (S.slice s1 i l)) (S.head s2)))
        i
        l;
    (S.equal) { }
      S.slice (
        S.upd (QUIC.Spec.pointwise_op f s1 (S.slice s2 1 (S.length s2)) (i + 1))
          i
          (f (S.head (S.slice s1 i l)) (S.head s2)))
        i
        l;
    (S.equal) {
      pointwise_upd f s1 (S.slice s2 1 (S.length s2)) i (i + 1)
        (f (S.head (S.slice s1 i l)) (S.head s2))
    }
      S.slice
        (QUIC.Spec.pointwise_op f
          (S.upd s1 i (f (S.head (S.slice s1 i l)) (S.head s2)))
          (S.slice s2 1 (S.length s2))
          (i + 1))
        i l;

    };
    ()
#pop-options

#push-options "--max_fuel 2 --initial_fuel 2 --max_ifuel 1 --initial_ifuel 1"
let rec and_inplace_commutative (s1 s2: S.seq U8.t): Lemma
  (requires S.length s1 = S.length s2)
  (ensures Spec.Loops.seq_map2 U8.logand s1 s2 `S.equal`
    Spec.Loops.seq_map2 U8.logand s2 s1)
  (decreases (S.length s1))
=
  if S.length s1 = 0 then
    ()
  else (
    FStar.UInt.logand_commutative #8 (U8.v (S.head s1)) (U8.v (S.head s2));
    assert (U8.logand (S.head s1) (S.head s2) = U8.logand (S.head s2) (S.head s1));
    and_inplace_commutative (S.tail s1) (S.tail s2);
    assert (Spec.Loops.seq_map2 U8.logand (S.tail s1) (S.tail s2) `S.equal`
      Spec.Loops.seq_map2 U8.logand (S.tail s2) (S.tail s1))
  )
#pop-options

let lemma_slice3 #a (s: S.seq a) (i j: nat): Lemma
  (requires (i <= j /\ j <= S.length s))
  (ensures (s `S.equal`
    (S.slice s 0 i `S.append` S.slice s i j `S.append` S.slice s j (S.length s))))
=
  ()

let lemma_slice0 #a (s: S.seq a): Lemma (S.slice s 0 (S.length s) `S.equal` s) = ()

let lemma_slice1 #a (s: S.seq a) (i j: nat): Lemma
  (requires (i <= j /\ j <= S.length s))
  (ensures (S.slice s 0 j `S.equal`
    (S.slice s 0 i `S.append` S.slice s i j)))
=
  ()

#push-options "--z3rlimit 200"
inline_for_extraction noextract
let op_inplace (dst: B.buffer U8.t)
  (dst_len: U32.t)
  (src: B.buffer U8.t)
  (src_len: U32.t)
  (ofs: U32.t)
  (op: U8.t -> U8.t -> U8.t)
:
  Stack unit
    (requires fun h0 ->
      B.(all_live h0 [ buf dst; buf src ]) /\
      B.disjoint dst src /\
      B.length src = U32.v src_len /\
      B.length dst = U32.v dst_len /\
      B.length dst >= U32.v ofs + B.length src)
    (ensures fun h0 _ h1 ->
      B.(modifies (loc_buffer dst) h0 h1) /\
      B.as_seq h1 dst `S.equal`
        QUIC.Spec.pointwise_op op (B.as_seq h0 dst) (B.as_seq h0 src) (U32.v ofs) /\
      S.slice (B.as_seq h0 dst) 0 (U32.v ofs) `S.equal`
        S.slice (B.as_seq h1 dst) 0 (U32.v ofs) /\
      S.slice (B.as_seq h0 dst) (U32.v (ofs `U32.add` src_len)) (U32.v dst_len) `S.equal`
      S.slice (B.as_seq h1 dst) (U32.v (ofs `U32.add` src_len)) (U32.v dst_len))
=
  let h0 = ST.get () in
  let dst0 = B.sub dst 0ul ofs in
  let dst1 = B.sub dst ofs src_len in
  let dst2 = B.sub dst (ofs `U32.add` src_len) (dst_len `U32.sub` (ofs `U32.add` src_len)) in
  C.Loops.in_place_map2 dst1 src src_len op;
  let h1 = ST.get () in
  calc (S.equal) {
    B.as_seq h1 dst;
  (S.equal) { lemma_slice3 (B.as_seq h1 dst) (U32.v ofs) (U32.v (ofs `U32.add` src_len)) }
    S.slice (B.as_seq h1 dst) 0 (U32.v ofs) `S.append`
    (S.slice (B.as_seq h1 dst) (U32.v ofs) (U32.v (ofs `U32.add` src_len))) `S.append`
    (S.slice (B.as_seq h1 dst) (U32.v (ofs `U32.add` src_len)) (B.length dst));
  (S.equal) {}
    S.slice (B.as_seq h0 dst) 0 (U32.v ofs) `S.append`
    (S.slice (B.as_seq h1 dst) (U32.v ofs) (U32.v (ofs `U32.add` src_len))) `S.append`
    (S.slice (B.as_seq h0 dst) (U32.v (ofs `U32.add` src_len)) (B.length dst));
  (S.equal) { pointwise_seq_map2 op (B.as_seq h0 dst1) (B.as_seq h0 src) 0 }
    S.slice (B.as_seq h0 dst) 0 (U32.v ofs) `S.append`
    (QUIC.Spec.pointwise_op op
      (S.slice (B.as_seq h0 dst) (U32.v ofs) (U32.v (ofs `U32.add` src_len)))
      (B.as_seq h0 src)
      0) `S.append`
    (S.slice (B.as_seq h0 dst) (U32.v (ofs `U32.add` src_len)) (B.length dst));
  (S.equal) { QUIC.Spec.pointwise_op_suff op (S.slice (B.as_seq h0 dst) 0 (U32.v ofs))
    (S.slice (B.as_seq h0 dst) (U32.v ofs) (U32.v (ofs `U32.add` src_len)))
    (B.as_seq h0 src)
    (U32.v ofs) }
    QUIC.Spec.pointwise_op op
      (S.append (S.slice (B.as_seq h0 dst) 0 (U32.v ofs))
        (S.slice (B.as_seq h0 dst) (U32.v ofs) (U32.v (ofs `U32.add` src_len))))
      (B.as_seq h0 src)
      (U32.v ofs) `S.append`
    (S.slice (B.as_seq h0 dst) (U32.v (ofs `U32.add` src_len)) (B.length dst));
  (S.equal) { lemma_slice1 (B.as_seq h0 dst) (U32.v ofs) (U32.v (ofs `U32.add` src_len)) }
    QUIC.Spec.pointwise_op op
      (S.slice (B.as_seq h0 dst) 0 (U32.v (ofs `U32.add` src_len)))
      (B.as_seq h0 src)
      (U32.v ofs) `S.append`
    (S.slice (B.as_seq h0 dst) (U32.v (ofs `U32.add` src_len)) (B.length dst));
  (S.equal) { QUIC.Spec.pointwise_op_pref op
    (S.slice (B.as_seq h0 dst) 0 (U32.v (ofs `U32.add` src_len)))
    (S.slice (B.as_seq h0 dst) (U32.v (ofs `U32.add` src_len)) (B.length dst))
    (B.as_seq h0 src)
    (U32.v ofs)
  }
    QUIC.Spec.pointwise_op op
      (S.slice (B.as_seq h0 dst) 0 (U32.v (ofs `U32.add` src_len)) `S.append`
      (S.slice (B.as_seq h0 dst) (U32.v (ofs `U32.add` src_len)) (B.length dst)))
      (B.as_seq h0 src)
      (U32.v ofs);
  (S.equal) { lemma_slice (B.as_seq h0 dst) (U32.v (ofs `U32.add` src_len)) }
    QUIC.Spec.pointwise_op op
      (B.as_seq h0 dst)
      (B.as_seq h0 src)
      (U32.v ofs);
  }


let format_header (dst: B.buffer U8.t) (h: header) (npn: B.buffer U8.t) (pn_len: u2):
  Stack unit
    (requires (fun h0 ->
      B.length dst = QUIC.Spec.header_len (g_header h h0) (U8.v pn_len) /\
      B.length npn = 1 + U8.v pn_len /\
      header_live h h0 /\
      header_disjoint h /\
      B.(all_disjoint [ loc_buffer dst; header_footprint h; loc_buffer npn ])))
    (ensures (fun h0 _ h1 ->
      B.(modifies (loc_buffer dst) h0 h1) /\ (
      let fh = QUIC.Spec.format_header (g_header h h0) (B.as_seq h0 npn) in
      S.slice (B.as_seq h1 dst) 0 (S.length fh) `S.equal` fh)))
=
  admit ();
  C.Failure.failwith C.String.(!$"TODO")

let vlen (n:u62) : x:U8.t { U8.v x = QUIC.Spec.vlen (U64.v n) } =
  assert_norm (pow2 6 = 64);
  assert_norm (pow2 14 = 16384);
  assert_norm (pow2 30 = 1073741824);
  if n `U64.lt` 64UL then 1uy
  else if n `U64.lt` 16384UL then 2uy
  else if n `U64.lt` 1073741824UL then 4uy
  else 8uy

let header_len (h: header) (pn_len: u2): Stack U32.t
  (requires fun h0 -> True)
  (ensures fun h0 x h1 ->
    U32.v x = QUIC.Spec.header_len (g_header h h0) (U8.v pn_len) /\
    h0 == h1)
=
  [@inline_let]
  let u32_of_u8 = FStar.Int.Cast.uint8_to_uint32 in
  [@inline_let]
  let u64_of_u32 = FStar.Int.Cast.uint32_to_uint64 in
  match h with
  | Short _ _ _ cid_len ->
      U32.(1ul +^ u32_of_u8 cid_len +^ 1ul +^ u32_of_u8 pn_len)
  | Long _ _ _ dcil _ scil plain_len ->
      assert_norm (pow2 32 < pow2 62);
      U32.(6ul +^ u32_of_u8 (add3 dcil) +^ u32_of_u8 (add3 scil) +^
        u32_of_u8 (vlen (u64_of_u32 plain_len)) +^ 1ul +^ u32_of_u8 pn_len)

let block_len (a: Spec.Agile.Cipher.cipher_alg):
  x:U32.t { U32.v x = Spec.Agile.Cipher.block_length a }
=
  let open Spec.Agile.Cipher in
  match a with | CHACHA20 -> 64ul | _ -> 16ul

#push-options "--max_fuel 1"
let rec seq_map2_xor0 (s1 s2: S.seq U8.t): Lemma
  (requires
    S.length s1 = S.length s2 /\
    s1 `S.equal` S.create (S.length s2) 0uy)
  (ensures
    Spec.Loops.seq_map2 CTR.xor8 s1 s2 `S.equal` s2)
  (decreases (S.length s1))
=
  if S.length s1 = 0 then
    ()
  else
    let open FStar.UInt in
    logxor_lemma_1 #8 (U8.v (S.head s2));
    logxor_lemma_1 #8 (U8.v (S.head s1));
    logxor_commutative (U8.v (S.head s1)) (U8.v (S.head s2));
    seq_map2_xor0 (S.tail s1) (S.tail s2)
#pop-options

#push-options "--z3rlimit 100"
inline_for_extraction
let block_of_sample (a: Spec.Agile.Cipher.cipher_alg)
  (dst: B.buffer U8.t)
  (s: CTR.state a)
  (k: B.buffer U8.t)
  (sample: B.buffer U8.t):
  Stack unit
    (requires fun h0 ->
      B.(all_live h0 [ buf dst; buf k; buf sample ]) /\
      CTR.invariant h0 s /\
      B.(all_disjoint
        [ CTR.footprint h0 s; loc_buffer dst; loc_buffer k; loc_buffer sample ]) /\
      Spec.Agile.Cipher.(a == AES128 \/ a == AES256 \/ a == CHACHA20) /\
      B.length k = Spec.Agile.Cipher.key_length a /\
      B.length dst = 16 /\
      B.length sample = 16)
    (ensures fun h0 _ h1 ->
      B.(modifies (loc_buffer dst `loc_union` CTR.footprint h0 s) h0 h1) /\
      B.as_seq h1 dst `S.equal`
        QUIC.Spec.block_of_sample a (B.as_seq h0 k) (B.as_seq h0 sample) /\
      CTR.footprint h0 s == CTR.footprint h1 s /\
      CTR.invariant h1 s)
=
  push_frame ();
  (**) let h0 = ST.get () in
  let zeroes = B.alloca 0uy (block_len a) in
  let dst_block = B.alloca 0uy (block_len a) in
  begin match a with
  | Spec.Agile.Cipher.CHACHA20 ->
      let ctr = LowStar.Endianness.load32_le (B.sub sample 0ul 4ul) in
      let iv = B.sub sample 4ul 12ul in
      (**) let h1 = ST.get () in
      CTR.init (G.hide a) s k iv 12ul ctr;
      CTR.update_block (G.hide a) s dst_block zeroes;
      (**) let h2 = ST.get () in
      (**) seq_map2_xor0 (B.as_seq h1 dst_block)
      (**)   (Spec.Agile.Cipher.ctr_block a (B.as_seq h0 k) (B.as_seq h1 iv) (U32.v ctr));
      (**) assert (B.as_seq h2 dst_block `S.equal`
      (**)   Spec.Agile.Cipher.ctr_block a (B.as_seq h0 k) (B.as_seq h1 iv) (U32.v ctr));
      let dst_slice = B.sub dst_block 0ul 16ul in
      (**) assert (B.as_seq h2 dst_slice `S.equal` S.slice (
      (**)   Spec.Agile.Cipher.ctr_block a (B.as_seq h0 k) (B.as_seq h1 iv) (U32.v ctr)
      (**) ) 0 16);
      B.blit dst_slice 0ul dst 0ul 16ul
  | _ ->
      let ctr = LowStar.Endianness.load32_be (B.sub sample 12ul 4ul) in
      let iv = B.sub sample 0ul 12ul in
      (**) let h1 = ST.get () in
      CTR.init (G.hide a) s k iv 12ul ctr;
      CTR.update_block (G.hide a) s dst_block zeroes;
      (**) let h2 = ST.get () in
      (**) seq_map2_xor0 (B.as_seq h1 dst_block)
      (**)   (Spec.Agile.Cipher.ctr_block a (B.as_seq h0 k) (B.as_seq h1 iv) (U32.v ctr));
      (**) assert (B.as_seq h2 dst_block `S.equal`
      (**)   Spec.Agile.Cipher.ctr_block a (B.as_seq h0 k) (B.as_seq h1 iv) (U32.v ctr));
      let dst_slice = B.sub dst_block 0ul 16ul in
      (**) assert (B.as_seq h2 dst_slice `S.equal` S.slice (
      (**)   Spec.Agile.Cipher.ctr_block a (B.as_seq h0 k) (B.as_seq h1 iv) (U32.v ctr)
      (**) ) 0 16);
      B.blit dst_slice 0ul dst 0ul 16ul

  end;
  pop_frame ()
#pop-options

let proj_ctr_state #i (s: state i): Stack (CTR.state (as_cipher_alg i.aead_alg))
  (requires (fun h0 -> invariant h0 s))
  (ensures (fun h0 x h1 -> h0 == h1 /\ x == (B.deref h0 s).ctr_state))
=
  let State _ _ _ _ _ _ _ _ s = !*s in
  s

let pn_sizemask (dst: B.buffer U8.t) (pn_len: u2): Stack unit
  (requires fun h0 ->
    B.live h0 dst /\ B.length dst = 4)
  (ensures fun h0 _ h1 ->
    B.as_seq h1 dst `S.equal` QUIC.Spec.pn_sizemask (U8.v pn_len) /\
    B.(modifies (loc_buffer dst) h0 h1))
=
  let open FStar.Mul in
  [@ inline_let ]
  let pn_len32 = FStar.Int.Cast.uint8_to_uint32 pn_len in
  assert (U32.v pn_len32 = U8.v pn_len);
  assert_norm (0xffffffff = pow2 32 - 1);
  assert (24 - 8 * U32.v pn_len32 < 32);
  assert (24 - 8 * U32.v pn_len32 >= 0);
  FStar.UInt.shift_left_value_lemma #32 1 (24 - 8 * U32.v pn_len32);
  FStar.Math.Lemmas.pow2_lt_compat 32 (24 - 8 * U32.v pn_len32);
  FStar.Math.Lemmas.modulo_lemma (pow2 (24 - 8 * U32.v pn_len32)) (pow2 32);
  assert (U32.(v (1ul <<^ (24ul -^ 8ul *^ pn_len32))) = pow2 (24 - 8 * U32.v pn_len32));
  LowStar.Endianness.store32_be dst
    U32.(0xfffffffful -^ (1ul <<^ (24ul -^ 8ul *^ pn_len32)) +^ 1ul)

let g_hp_key #i h (s: state i) =
  B.as_seq h (State?.hp_key (B.deref h s))

let header_encrypt_pre
  (i: index)
  (dst:B.buffer U8.t)
  (dst_len:U32.t)
  (s:state i)
  (h:header)
  (cipher:G.erased QUIC.Spec.cbytes)
  (iv:G.erased (S.seq U8.t))
  (npn:B.buffer U8.t)
  (pn_len:u2)
  (h0: HS.mem)
=
  let h_len = QUIC.Spec.header_len (g_header h h0) (U8.v pn_len) in

  // Administrative: memory
  B.(all_live h0 [ buf dst; buf s; buf npn ]) /\
  invariant h0 s /\
  B.(all_disjoint [ footprint h0 s; loc_buffer dst; loc_buffer npn ]) /\

  // Administrative: lengths
  B.length dst = U32.v dst_len /\
  U32.v dst_len = h_len + S.length (G.reveal cipher) /\
  S.length (G.reveal iv) = 12 /\
  B.length npn = 1 + U8.v pn_len /\ (

  // ``dst`` contains formatted header + ciphertext
  let h_seq = S.slice (B.as_seq h0 dst) 0 h_len in
  let c = S.slice (B.as_seq h0 dst) h_len (U32.v dst_len) in
  h_seq `S.equal` QUIC.Spec.format_header (g_header h h0) (B.as_seq h0 npn) /\
  c `S.equal` G.reveal cipher)

val header_encrypt: i:G.erased index -> (
  let i = G.reveal i in
  dst:B.buffer U8.t ->
  dst_len:U32.t ->
  s:state i ->
  h:header ->
  cipher:G.erased QUIC.Spec.cbytes ->
  iv:G.erased (S.seq U8.t) ->
  npn:B.buffer U8.t ->
  pn_len:u2 ->
  Stack unit
    (requires header_encrypt_pre i dst dst_len s h cipher iv npn pn_len)
    (ensures fun h0 _ h1 ->
      B.(modifies (loc_buffer dst `loc_union` footprint_s #i h0 (B.deref h0 s)) h0 h1) /\
      B.as_seq h1 dst `S.equal`
        QUIC.Spec.header_encrypt i.aead_alg (g_hp_key h0 s) (g_header h h0)
          (B.as_seq h0 npn) (G.reveal cipher) /\
      invariant h1 s /\
      footprint h0 s == footprint h1 s))

#push-options "--max_fuel 2 --initial_fuel 2 --max_ifuel 1 --initial_ifuel 1"
let upd_op_inplace (#a:eqtype) op (s: S.seq a) (x: a): Lemma
  (requires S.length s > 0)
  (ensures (S.upd s 0 (S.index s 0 `op` x) `S.equal`
    QUIC.Spec.pointwise_op op s (S.create 1 x) 0))
=
  ()
#pop-options

let pn_offset (h: header): Stack U32.t
  (requires fun h0 -> True)
  (ensures fun h0 x h1 ->
    U32.v x = QUIC.Spec.pn_offset (g_header h h0) /\ h0 == h1)
=
  (**) assert_norm (QUIC.Spec.max_cipher_length < pow2 62 /\ pow2 32 < pow2 62);
  [@inline_let] let u32_of_u8 = FStar.Int.Cast.uint8_to_uint32 in
  [@inline_let] let u64_of_u32 = FStar.Int.Cast.uint32_to_uint64 in
  match h with
  | Short _ _ _ cid_len ->
      1ul `U32.add` u32_of_u8 cid_len
  | Long _ _ _ dcil _ scil pl ->
      6ul `U32.add` u32_of_u8 (add3 dcil) `U32.add` u32_of_u8 (add3 scil)
        `U32.add` u32_of_u8 (vlen (u64_of_u32 pl))


#push-options "--z3rlimit 1000"
let header_encrypt i dst dst_len s h cipher iv npn pn_len =
  let State _ aead_alg _ _ aead_state _ k _ ctr_state = !*s in
  // [@inline_let]
  let u32_of_u8 = FStar.Int.Cast.uint8_to_uint32 in
  (**) assert (U32.v dst_len >= 4);
  (**) let h0  = ST.get () in

  let pn_offset = pn_offset h in
  let h_len = header_len h pn_len in
  let sample = B.sub dst (h_len `U32.add` 3ul `U32.sub` u32_of_u8 pn_len) 16ul in
  let c = B.sub dst h_len (dst_len `U32.sub` h_len) in
  (**) assert (U32.v h_len = QUIC.Spec.header_len (g_header h h0) (U8.v pn_len));
  (**) assert (U32.v dst_len = U32.v h_len + S.length (G.reveal cipher));
  (**) lemma_slice (B.as_seq h0 dst) (U32.v h_len);
  (**) assert (B.as_seq h0 c `S.equal` G.reveal cipher);
  (**) assert (B.as_seq h0 sample `S.equal`
  (**)   S.slice (G.reveal cipher) (3 - U8.v pn_len) (19 - U8.v pn_len));

  push_frame ();
  let mask = B.alloca 0uy 16ul in
  let pn_mask = B.alloca 0uy 4ul in
  (**) let h1 = ST.get () in
  (**) assert (B.(loc_disjoint (loc_buffer pn_mask) (footprint h1 s)));
  (**) assert (B.(all_live h1 [ buf mask; buf k; buf sample ]));

  (**) assert (CTR.invariant h1 ctr_state);
  (**) assert (invariant h1 s);
  (**) assert (B.(all_disjoint
    [ CTR.footprint h1 ctr_state; loc_buffer k ]));

  block_of_sample (as_cipher_alg aead_alg) mask ctr_state k sample;
  (**) let h2 = ST.get () in
  (**) assert (CTR.footprint h1 ctr_state == CTR.footprint h2 ctr_state);
  (**) assert (AEAD.footprint h1 aead_state == AEAD.footprint h2 aead_state);

  pn_sizemask pn_mask pn_len;
  (**) let h3 = ST.get () in
  (**) frame_invariant B.(loc_buffer pn_mask) s h2 h3;

  let sub_mask = B.sub mask 1ul 4ul in
  (**) assert (B.as_seq h3 sub_mask `S.equal` S.slice (B.as_seq h3 mask) 1 5);
  op_inplace pn_mask 4ul sub_mask 4ul 0ul U8.logand;
  (**) pointwise_seq_map2 U8.logand (B.as_seq h3 pn_mask) (B.as_seq h3 sub_mask) 0;
  (**) and_inplace_commutative (B.as_seq h3 pn_mask) (B.as_seq h3 sub_mask);
  (**) pointwise_seq_map2 U8.logand (B.as_seq h3 sub_mask) (B.as_seq h3 pn_mask) 0;
  (**) let h4 = ST.get () in
  (**) frame_invariant B.(loc_buffer pn_mask) s h3 h4;
  (**) assert (invariant h4 s);
  (**) assert (B.(loc_disjoint (footprint h4 s) (loc_buffer dst)));
  let sflags = if Short? h then 0x1fuy else 0x0fuy in
  let fmask = mask.(0ul) `U8.logand` sflags in

  op_inplace dst dst_len pn_mask 4ul pn_offset U8.logxor;
  (**) let h5 = ST.get () in
  (**) frame_invariant B.(loc_buffer dst) s h4 h5;
  (**) assert (invariant h5 s);

  dst.(0ul) <- dst.(0ul) `U8.logxor` fmask;
  (**) let h6 = ST.get () in
  (**) frame_invariant B.(loc_buffer dst) s h5 h6;
  (**) assert (invariant h6 s);
  (**) upd_op_inplace U8.logxor (B.as_seq h5 dst) fmask;
  assert (
    let the_npn = npn in
    let open QUIC.Spec in
    let a = aead_alg in
    let k = B.as_seq h0 k in
    let h = g_header h h0 in
    let npn = B.as_seq h0 the_npn in
    let c = G.reveal cipher in
    B.as_seq h6 dst `S.equal` QUIC.Spec.header_encrypt aead_alg k h npn c);
  pop_frame ();
  (**) let h7 = ST.get () in
  ()

open FStar.Mul

let rec be_to_n_slice (s: S.seq U8.t) (i: nat): Lemma
  (requires i <= S.length s)
  (ensures FStar.Endianness.be_to_n (S.slice s i (S.length s)) =
    FStar.Endianness.be_to_n s % pow2 (8 `op_Multiply` (S.length s - i)))
  (decreases (S.length s))
=
  FStar.Endianness.reveal_be_to_n s;
  if S.length s = 0 then
    ()
  else
    let open FStar.Endianness in
    if i = S.length s then begin
      reveal_be_to_n S.empty;
      assert_norm (pow2 (8 * 0) = 1);
      assert (S.slice s (S.length s) (S.length s) `S.equal` S.empty);
      assert (be_to_n S.empty = 0);
      assert (be_to_n s % 1 = 0)
    end else
      let s' = (S.slice s i (S.length s)) in
      let s_prefix = (S.slice s 0 (S.length s - 1)) in
      assert (S.length s' <> 0);
      assert (8 <= 8 * (S.length s - i));
      FStar.Math.Lemmas.pow2_le_compat (8 * (S.length s - i)) 8;
      assert_norm (pow2 (8 * 1) = 256);
      assert (U8.v (S.last s) < pow2 (8 * (S.length s - i)));
      assert (S.length s' = S.length s_prefix - i + 1);
      FStar.Math.Lemmas.pow2_le_compat (8 * (S.length s')) (8 * (S.length s - i));
      calc (==) {
        be_to_n s';
      (==) {
        lemma_be_to_n_is_bounded s';
        FStar.Math.Lemmas.small_mod (be_to_n s') (pow2 (8 * (S.length s - i)))
      }
        (be_to_n s') % (pow2 (8 * (S.length s - i)));
      (==) { reveal_be_to_n s' }
        (U8.v (S.last s') + pow2 8 * be_to_n (S.slice s' 0 (S.length s' - 1))) %
          (pow2 (8 * (S.length s - i)));
      (==) { }
        (U8.v (S.last s) + pow2 8 * be_to_n (S.slice s i (S.length s - 1))) %
          (pow2 (8 * (S.length s - i)));
      (==) { }
        (U8.v (S.last s) + pow2 8 * (be_to_n (S.slice s_prefix i (S.length s_prefix)))) %
          (pow2 (8 * (S.length s - i)));
      (==) { be_to_n_slice s_prefix i }
        (U8.v (S.last s) + pow2 8 * (be_to_n s_prefix % pow2 (8 * (S.length s_prefix - i)))) %
          (pow2 (8 * (S.length s - i)));
      (==) { FStar.Math.Lemmas.pow2_multiplication_modulo_lemma_2
        (be_to_n s_prefix) (8 * (S.length s_prefix - i) + 8) 8
      }
        (U8.v (S.last s) +
          ((be_to_n s_prefix * pow2 8) % pow2 (8 * (S.length s_prefix - i) + 8))
        ) %
          (pow2 (8 * (S.length s - i)));
      (==) { }
        (U8.v (S.last s) +
          ((be_to_n s_prefix * pow2 8) % pow2 (8 * (S.length s - i)))
        ) %
          (pow2 (8 * (S.length s - i)));
      (==) { FStar.Math.Lemmas.lemma_mod_add_distr
        (U8.v (S.last s))
        (be_to_n s_prefix * pow2 8)
        (pow2 (8 * (S.length s - i)))
      }
        (U8.v (S.last s) + pow2 8 * be_to_n (S.slice s 0 (S.length s - 1))) %
          pow2 (8 * (S.length s - i));
      }

let tag_len (a: QUIC.Spec.ea): x:U32.t { U32.v x = Spec.Agile.AEAD.tag_length a /\ U32.v x = 16} =
  let open Spec.Agile.AEAD in
  match a with
  | CHACHA20_POLY1305 -> 16ul
  | AES128_GCM        -> 16ul
  | AES256_GCM        -> 16ul

inline_for_extraction
let tricky_addition (aead_alg: QUIC.Spec.ea) (h: header) (pn_len: u2) (plain_len: U32.t {
    3 <= U32.v plain_len /\
    U32.v plain_len < QUIC.Spec.max_plain_length
  }):
  Stack U32.t
    (requires fun h0 -> header_live h h0)
    (ensures fun h0 x h1 ->
      h0 == h1 /\
      U32.v x = QUIC.Spec.header_len (g_header h h0) (U8.v pn_len) + U32.v plain_len +
        Spec.Agile.AEAD.tag_length aead_alg)
=
  header_len h pn_len `U32.add` plain_len `U32.add` tag_len aead_alg

#set-options "--query_stats --z3rlimit 1000"
let encrypt #i s dst h plain plain_len pn_len =
  // [@inline_let]
  let u32_of_u8 = FStar.Int.Cast.uint8_to_uint32 in
  let State hash_alg aead_alg e_traffic_secret e_initial_pn
    aead_state iv hp_key pn ctr_state = !*s
  in
  (**) let h0 = ST.get () in
  (**) assert (
  (**)   let s0 = g_traffic_secret (B.deref h0 s) in
  (**)   let open QUIC.Spec in
  (**)   let k = derive_secret i.hash_alg s0 label_key (Spec.Agile.AEAD.key_length i.aead_alg) in
  (**)   let iv_seq = derive_secret i.hash_alg s0 label_iv 12 in
  (**)   let hp_key_seq = derive_secret i.hash_alg s0 label_hp (ae_keysize i.aead_alg) in
  (**)   AEAD.as_kv (B.deref h0 aead_state) `S.equal` k /\
  (**)   B.as_seq h0 iv `S.equal` iv_seq /\
  (**)   B.as_seq h0 hp_key `S.equal` hp_key_seq);

  push_frame ();
  (**) let h01 = ST.get () in
  let pnb0 = B.alloca 0uy 16ul in
  (**) assert B.(loc_includes (loc_all_regions_from false (HS.get_tip h01)) (loc_buffer pnb0));
  (**) B.(modifies_loc_includes
    (loc_all_regions_from false (HS.get_tip h01) `loc_union`
      footprint_s h0 (deref h0 s) `loc_union` loc_buffer dst)
    h0 h01 (loc_all_regions_from false (HS.get_tip h01)));

  // JP: cannot inline this in the call below; why?
  let pn: U64.t = !*pn in
  let pn128: FStar.UInt128.t = FStar.Int.Cast.Full.uint64_to_uint128 pn in
  LowStar.Endianness.store128_be pnb0 pn128;
  (**) let h02 = ST.get () in
  (**) frame_invariant B.(loc_buffer pnb0) s h01 h02;
  (**) B.(modifies_loc_includes
    (loc_all_regions_from false (HS.get_tip h01) `loc_union`
      footprint_s h0 (deref h0 s) `loc_union` loc_buffer dst)
    h01 h02 (loc_all_regions_from false (HS.get_tip h01)));

  let pnb = B.sub pnb0 4ul 12ul in
  (**) let h1 = ST.get () in
  (**) (
  (**) let open FStar.Endianness in
  (**) assert_norm (pow2 64 < pow2 (8 * 12));
  (**) calc (==) {
  (**)   be_to_n (B.as_seq h1 pnb);
  (**) (==) { }
  (**)   be_to_n (S.slice (B.as_seq h1 pnb0) 4 16);
  (**) (==) { be_to_n_slice (B.as_seq h1 pnb0) 4 }
  (**)   be_to_n (B.as_seq h1 pnb0) % pow2 (8 * 12);
  (**) (==) { FStar.Math.Lemmas.small_mod (U64.v pn) (pow2 (8 * 12)) }
  (**)   be_to_n (B.as_seq h1 pnb0);
  (**) });
  (**) assert (B.as_seq h1 pnb `S.equal`
  (**)   FStar.Endianness.n_to_be 12 (g_packet_number (B.deref h1 s) h1));

  let npn = B.sub pnb (11ul `U32.sub` u32_of_u8 pn_len) (1ul `U32.add` u32_of_u8 pn_len) in
  (**) assert (B.as_seq h1 npn `S.equal` S.slice (B.as_seq h1 pnb) (11 - U8.v pn_len) 12);
  let dst_h = B.sub dst 0ul (header_len h pn_len) in
  let dst_ciphertag = B.sub dst (header_len h pn_len) (plain_len `U32.add` tag_len aead_alg) in
  let dst_cipher = B.sub dst_ciphertag 0ul plain_len in
  let dst_tag = B.sub dst_ciphertag plain_len (tag_len aead_alg) in
  format_header dst_h h npn pn_len;
  (**) let h10 = ST.get () in
  (**) frame_invariant B.(loc_buffer dst) s h02 h10;
  (**) assert (let h_len = QUIC.Spec.header_len (g_header h h0) (U8.v pn_len) in
  (**)   S.slice (B.as_seq h10 dst) 0 h_len `S.equal`
  (**)     QUIC.Spec.format_header (g_header h h10) (B.as_seq h10 npn));
  (**) assert B.(loc_includes (loc_buffer dst) (loc_buffer dst_h));
  (**) B.(modifies_loc_includes
    (loc_all_regions_from false (HS.get_tip h01) `loc_union`
      footprint_s h0 (deref h0 s) `loc_union` loc_buffer dst)
    h1 h10 (loc_buffer dst));


  (**) QUIC.Spec.lemma_format_len aead_alg (g_header h h0) (B.as_seq h1 npn);
  let this_iv = B.alloca 0uy 12ul in
  (**) let h11 = ST.get () in
  (**) assert B.(loc_includes (loc_all_regions_from false (HS.get_tip h01)) (loc_buffer this_iv));
  (**) B.(modifies_loc_includes
    (loc_all_regions_from false (HS.get_tip h01) `loc_union`
      footprint_s h0 (deref h0 s) `loc_union` loc_buffer dst)
    h10 h11 (loc_all_regions_from false (HS.get_tip h01)));

  C.Loops.map2 this_iv pnb iv 12ul U8.logxor;
  (**) pointwise_seq_map2 U8.logxor (B.as_seq h10 pnb) (B.as_seq h10 iv) 0;
  (**) let h2 = ST.get () in
  (**) assert (let h_len = QUIC.Spec.header_len (g_header h h0) (U8.v pn_len) in
  (**)   S.slice (B.as_seq h2 dst) 0 h_len `S.equal`
  (**)     QUIC.Spec.format_header (g_header h h2) (B.as_seq h2 npn));
  (**) frame_invariant B.(loc_buffer this_iv) s h10 h2;
  // JP: hard
  (**) assert (footprint_s h0 (B.deref h0 s) == footprint_s h2 (B.deref h2 s));
  (**) B.(modifies_loc_includes
    (loc_all_regions_from false (HS.get_tip h01) `loc_union`
      footprint_s h0 (deref h0 s) `loc_union` loc_buffer dst)
    h11 h2 (loc_all_regions_from false (HS.get_tip h01)));

  let l = header_len h pn_len in
  // JP: adding assert here SIGNIFICANTLY reduces verification time; what's hard?
  (**) assert (AEAD.encrypt_pre aead_alg aead_state this_iv 12ul dst_h l
  (**)   plain plain_len dst_cipher dst_tag h2);
  let r = AEAD.encrypt #(G.hide aead_alg) aead_state
    this_iv 12ul dst_h (header_len h pn_len) plain plain_len dst_cipher dst_tag in
  (**) assert (r = Success);
  (**) let h3 = ST.get () in
  // JP: incredibly hard; takes two minutes extra on my machine to prove this
  (**) assert (footprint_s h2 (B.deref h2 s) == footprint_s h3 (B.deref h3 s));
  (**) assert (invariant h3 s);
  // JP: also hard
  (**) assert B.(modifies (AEAD.footprint h2 aead_state `loc_union` loc_buffer dst_cipher
  (**)   `loc_union` loc_buffer dst_tag) h2 h3);
  (**) assert B.(loc_includes (footprint_s h2 (B.deref h2 s)) (AEAD.footprint h2 aead_state));
  (**) assert B.(loc_includes (loc_buffer dst)
  (**)   (loc_buffer dst_cipher `loc_union` loc_buffer dst_tag));
  // JP: adds a minute
  B.(modifies_loc_includes
    (loc_all_regions_from false (HS.get_tip h01) `loc_union`
      footprint_s h0 (deref h0 s) `loc_union` loc_buffer dst)
    h2 h3 (footprint_s h0 (deref h0 s) `loc_union` loc_buffer dst));

  // JP: without this side definition, this is an extra 30s of verification time
  let dst_len = tricky_addition aead_alg h pn_len plain_len in
  (**) assert (B.length dst = U32.v dst_len);
  (**) assert (B.length dst_ciphertag >= 19);
  (**) assert (B.length dst_ciphertag < QUIC.Spec.max_cipher_length);
  (**) let e_cipher:G.erased (QUIC.Spec.cbytes) = G.elift1
  (**)   (fun (b: B.buffer U8.t { B.length b = B.length dst_ciphertag }) ->
  (**)     ((B.as_seq h3 b) <: QUIC.Spec.cbytes)) (G.hide dst_ciphertag)
  (**) in
  (**) let e_iv = G.elift1 (B.as_seq h2) (G.hide pnb) in
  (**) assert (let h_len = QUIC.Spec.header_len (g_header h h0) (U8.v pn_len) in
  (**)   S.slice (B.as_seq h3 dst) 0 h_len `S.equal`
  (**)     QUIC.Spec.format_header (g_header h h3) (B.as_seq h3 npn));
  (**) assert (header_encrypt_pre (G.reveal i) dst dst_len s h e_cipher e_iv npn pn_len h3);
  header_encrypt i dst dst_len s h e_cipher e_iv npn pn_len;
  (**) let h4 = ST.get () in
  (**) B.(modifies_loc_includes
    (loc_all_regions_from false (HS.get_tip h01) `loc_union`
      footprint_s h0 (deref h0 s) `loc_union` loc_buffer dst)
    h3 h4 (footprint_s h0 (deref h0 s) `loc_union` loc_buffer dst));
  (**) assert (invariant h4 s);
  pop_frame ();

  (**) let h5 = ST.get () in

  // JP: nearly three minutes extra for this
  (
  let l = B.(loc_all_regions_from false (HS.get_tip h01) `loc_union`
      footprint_s h0 (deref h0 s) `loc_union` loc_buffer dst) in
  (**) B.(modifies_trans l h01 h02 l h1);
  (**) B.(modifies_trans l h01 h1 l h10);
  (**) B.(modifies_trans l h01 h10 l h11);
  (**) B.(modifies_trans l h01 h11 l h2);
  (**) B.(modifies_trans l h01 h2 l h3);
  (**) B.(modifies_trans l h01 h3 l h4);
  (**) B.(modifies_fresh_frame_popped h0 h01
  (**)   (footprint_s h0 (deref h0 s) `loc_union` loc_buffer dst) h4 h5)
  );
  (**) assert (
  (**)   B.(modifies (footprint_s h0 (deref h0 s) `loc_union` loc_buffer dst)) h0 h5);
  (**) assert B.(modifies (loc_all_regions_from false (HS.get_tip h01) `loc_union`
  (**)   footprint_s h0 (deref h0 s) `loc_union` loc_buffer dst) h01 h4);

  (**) B.popped_modifies h4 h5;
  (**) frame_invariant B.(loc_region_only false (HS.get_tip h4)) s h4 h5;
  (**) assert (invariant h5 s);
  (**) assert (footprint h4 s == footprint h3 s);

  admit ();

    (*// Functional correctness
    let s0 = g_traffic_secret (B.deref h0 s) in
    let open QUIC.Spec in
    let k = derive_secret i.hash_alg s0 label_key (Spec.Agile.AEAD.key_length i.aead_alg) in
    let iv = derive_secret i.hash_alg s0 label_iv 12 in
    let pne = derive_secret i.hash_alg s0 label_hp (ae_keysize i.aead_alg) in
    let plain: pbytes = B.as_seq h0 plain in
    let packet: packet = B.as_seq h1 dst in
    let ctr = g_packet_number (B.deref h0 s) h0 in
    packet ==
      QUIC.Spec.encrypt i.aead_alg k iv pne (U8.v pn_len) ctr (g_header h h0) plain)

  );*)

  Success

let decrypt #i s dst packet len cid_len =
  admit ()

