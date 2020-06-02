module Model.QUIC

module HS = FStar.HyperStack 
module I = Model.Indexing
module U32 = FStar.UInt32
module U64 = FStar.UInt64
module U128 = FStar.UInt128
module M = LowStar.Modifies

module Spec = QUIC.Spec
module Real = Model.QUIC.Spec
module AE = Model.AEAD
module PNE = Model.PNE

open FStar.Bytes
open FStar.UInt32
open Mem

(* WIP

let plain (i:I.id) (l:plainLen) = lbytes l

let plain_as_bytes (i:I.id) (l:plainLen) (p:plain i l) = p

let mk_plain i l b =
  if AEAD.safeId i then
    Bytes.create (U32.uint_to_t l) (U8.uint_to_t 0)
  else
    b

let plain_repr i l p = p


let nonce (i:I.id) (nl:pnlen) : (t:Type0{hasEq t}) = AEAD.iv (I.cipherAlg_of_id i)

let nonce_as_bytes (i:I.id) (nl:pnlen) (n:nonce i nl) : GTot (AEAD.iv (I.cipherAlg_of_id i)) = n

let nonce_repr (i:I.id{~(safeId i)}) (nl:pnlen) (n:nonce i nl) :
  Tot (r:AEAD.iv (I.cipherAlg_of_id i){r == nonce_as_bytes i nl n}) = n

let npn j nl = lbytes nl

let npn_as_bytes j nl n = n

let mk_npn j nl b = b

let npn_repr j nl n = n

let npn_from_bytes j nl b = b

let npn_abs j nl b = b
   
#reset-options "--z3rlimit 50"
let npn_encode j rpn nl =
  match nl with
    | 1 -> 
      Math.Lemmas.pow2_le_compat 64 7;  
      let x = U64.uint_to_t (pow2 7 - 1) in
      let y = U64.(rpn &^ x) in
      FStar.UInt.logand_le (U64.v rpn) (U64.v x);
      Bytes.bytes_of_int 1 (U64.v y)
    | 2 -> 
      Math.Lemmas.pow2_le_compat 64 14;  
      let x = U64.uint_to_t (pow2 14 - 1) in
      let y = U64.(rpn &^ x) in
      FStar.UInt.logand_le (U64.v rpn) (U64.v x);
      Math.Lemmas.pow2_lt_compat 64 15;  
      let x' = U64.uint_to_t (pow2 15) in
      assert (U64.v y + U64.v x' <= pow2 15 + pow2 14 - 1);
      assert (U64.v y + U64.v x' <= FStar.Mul.(2*(pow2 15) - 1));
      assert (U64.v y + U64.v x' <= pow2 16 - 1);
      let z = U64.(y +^ x') in
      Bytes.bytes_of_int 2 (U64.v z)
    | 4 -> 
      Math.Lemmas.pow2_le_compat 64 30;  
      let x = U64.uint_to_t (pow2 30 - 1) in
      let y = U64.(rpn &^ x) in
      FStar.UInt.logand_le (U64.v rpn) (U64.v x);
      Math.Lemmas.pow2_lt_compat 64 30;  
      Math.Lemmas.pow2_lt_compat 64 31;  
      let x' = U64.uint_to_t (pow2 30) in
      let x'' = U64.uint_to_t (pow2 31) in
      assert (U64.v y + U64.v x' <= pow2 30 + pow2 30 - 1);
      assert (U64.v y + U64.v x' <= FStar.Mul.(2*(pow2 30) - 1));
      assert (U64.v y + U64.v x' <= pow2 31 - 1);
      let y' = U64.(y +^ x') in
      assert (U64.v y' + U64.v x'' <= pow2 31 + pow2 31 - 1);
      assert (U64.v y' + U64.v x'' <= FStar.Mul.(2*(pow2 31) - 1));
      assert (U64.v y' + U64.v x'' <= pow2 32 - 1);
      let z = U64.(y' +^ x'') in
      Bytes.bytes_of_int 4 (U64.v z)

val lemma_mod_aux: a:nat -> p:pos -> Lemma (a % p <= a)
let lemma_mod_aux a p =
  if a < p then
    (Math.Lemmas.modulo_lemma a p)
  else
    (Math.Lemmas.lemma_mod_lt a p)
    
#reset-options "--z3rlimit 70"

let npn_decode #j #nl n expected_pn =
  let npn_32 = U32.uint_to_t (Bytes.int_of_bytes n) in
  let nl' =
    match nl with
      | 1 -> 7
      | 2 -> 14
      | 4 -> 30
  in
  let nl_mask32 = U32.uint_to_t (pow2 nl' - 1) in
  let nl_mask64 = U64.uint_to_t (pow2 nl' - 1) in
  let npn'32 = U32.logand npn_32 nl_mask32 in
  let npn' = U32.v npn'32 in
  let exppn'64 = U64.(logand expected_pn nl_mask64) in
  let exppn' = U64.v exppn'64 in
  UInt.logand_mask #64 (U64.v expected_pn) nl';
  assert (exppn' == U64.v expected_pn % (pow2 nl'));
  Math.Lemmas.modulo_range_lemma (U64.v expected_pn) (pow2 nl');
  lemma_mod_aux (U64.v expected_pn) (pow2 nl');
  assert (exppn' <= U64.v expected_pn);
  let exppn'' = U64.(expected_pn -^ exppn'64) in
  Math.Lemmas.lemma_div_mod (U64.v expected_pn) (pow2 nl');
  assert (U64.v exppn'' = FStar.Mul.(((U64.v expected_pn)/(pow2 nl'))*(pow2 nl')));
  assert ((U64.v expected_pn) < pow2 62);
  Math.Lemmas.lemma_div_lt (U64.v expected_pn) 62 nl';
  assert ((U64.v expected_pn)/(pow2 nl') < (pow2 (62 - nl')));
  assert ((U64.v expected_pn)/(pow2 nl') <= (pow2 (62 - nl')) - 1);
  Math.Lemmas.lemma_mult_le_right (pow2 nl') ((U64.v expected_pn)/(pow2 nl')) (pow2 (62 - nl') - 1);
  assert (FStar.Mul.(((U64.v expected_pn)/(pow2 nl'))*(pow2 nl') <= (pow2 (62 - nl') - 1)*(pow2 nl')));
  Math.Lemmas.distributivity_sub_left (pow2 (62 - nl')) 1 (pow2 nl');
  assert (FStar.Mul.(((U64.v expected_pn)/(pow2 nl'))*(pow2 nl') <= (pow2 (62 - nl'))*(pow2 nl') - pow2 nl'));
  Math.Lemmas.pow2_plus (62 - nl') nl';
  assert (U64.v exppn'' <= pow2 62 - pow2 nl');
  UInt.logand_le #32 (U32.v npn_32) (U32.v nl_mask32);
  assert (npn' <= pow2 nl' - 1);
  let nnn = (Int.Cast.uint32_to_uint64 npn'32) in
  assert (U64.v nnn = U32.v npn'32);
  assert (U64.v nnn = npn');
  assert (U64.v exppn'' + U64.v nnn <= pow2 62 - 1);
  let t = pow2 (nl' - 1) in
  if exppn' <= npn' then // npn is larger than the least significant bits of exp_pn
    if npn' - exppn' < t then // they are close enough: the most significant bits of rpn are the same as exp_pn
      U64.(exppn'' +^ nnn)
    else // they are not close: the most significant bits of rpn are (the same as exp_pn) - 1 (if possible)
         // (also covers the case where npn' = exppn' + t, where there are two possibilities and we take the smallest)
      if U64.v exppn'' >= pow2 nl' then 
        (assert (U64.v exppn'' - pow2 nl' + U64.v nnn <= pow2 62 - 1);
        U64.(exppn''  -^ uint_to_t (pow2 nl') +^ nnn))
      else
      U64.(exppn'' +^ nnn)
  else // exppn' > npn': npn is smaller than the least significant bits of exp_pn
    if exppn' - npn' <= t then // they are close enough: the most significant bits of rpn are the same as exp_pn
      // (also covers the case where exppn' = npn' + t, where there are two possibilities and we take the smallest)
      U64.(exppn'' +^ nnn)
    else // they are not close: the most signifiant bits of rpn are (the same as exp_pn) + 1 (if possible)
      if U64.v exppn'' + pow2 nl' <= pow2 62 - pow2 nl' then
        (assert (U64.v exppn'' + pow2 nl' + U64.v nnn <= pow2 62 - 1);
        U64.(exppn''  +^ uint_to_t (pow2 nl') +^ nnn))
      else
      U64.(exppn'' +^ nnn)




let encode_nl (nl:pnlen) : (x:U64.t{U64.v x<=pow2 63 + pow2 62}) =
  match nl with
    | 1 -> U64.uint_to_t 0
    | 2 -> U64.uint_to_t (pow2 63)
    | 4 ->
      assert (pow2 63 + pow2 62 < FStar.Mul.(2 * pow2 63));
      assert (pow2 63 + pow2 62 < pow2 64);
      U64.uint_to_t (pow2 63 + pow2 62)

// compute the nonce, with a post condition that helps to invert the function
val create_nonce_aux
  (#i:I.id)
  (#alg:I.cipherAlg{alg == I.cipherAlg_of_id i})
  (iv: AEAD.iv alg)
  (nl:pnlen)
  (r:rpn) :
  Pure (nonce i nl)
  (requires True)
  (ensures fun n' ->
    (let ll = v (AEAD.ivlen alg) in
    Bytes.fits_in_k_bytes (U128.v iv) ll /\
    (let iv_b = Bytes.bytes_of_int ll (U128.v iv) in
    let enc_nl = encode_nl nl in
    Bytes.fits_in_k_bytes (U128.v n') ll /\
    (let n_b' = Bytes.bytes_of_int ll (U128.v n') in
    let nlrpn_b' = Bytes.xor (AEAD.ivlen alg) n_b' iv_b in
      Bytes.int_of_bytes nlrpn_b' < pow2 64 /\
      Bytes.int_of_bytes nlrpn_b' >= U64.v enc_nl /\      
      U64.(uint_to_t (Bytes.int_of_bytes nlrpn_b') -^ enc_nl) = r))))

let create_nonce_aux #i #alg iv nl r = 
  //compute the nonce
  let ll = v (AEAD.ivlen alg) in 
  assert (Bytes.fits_in_k_bytes (U128.v iv) ll);
  let iv_b = Bytes.bytes_of_int ll (U128.v iv) in
  let enc_nl = encode_nl nl in
  let nlrpn = U64.(enc_nl +^ r) in
  assert (64 < FStar.Mul.(8 * ll));
  Math.Lemmas.pow2_lt_compat (FStar.Mul.(8*ll)) 64;
  //assert (Bytes.fits_in_k_bytes (U64.v nlrpn) ll);
  let nlrpn_b = Bytes.bytes_of_int ll (U64.v nlrpn) in 
  let n_b = Bytes.xor (AEAD.ivlen alg) iv_b nlrpn_b in
  let nn = Bytes.int_of_bytes n_b in
  Math.Lemmas.pow2_lt_compat 128 (FStar.Mul.(8*ll));
  let n = U128.uint_to_t nn in
  //prove the inversion
  let n_b' = Bytes.bytes_of_int ll (U128.v n) in
  assert (n_b' = n_b);
  let nlrpn_b' = Bytes.xor (AEAD.ivlen alg) n_b iv_b in
  Bytes.xor_commutative (AEAD.ivlen alg) iv_b nlrpn_b;
  assert (n_b = Bytes.xor (AEAD.ivlen alg) nlrpn_b iv_b);
  Bytes.xor_idempotent (AEAD.ivlen alg) nlrpn_b iv_b;
  assert (nlrpn_b' = nlrpn_b);
  Bytes.int_of_bytes_of_int #ll (U64.v nlrpn);
  let nlrpnn = Bytes.int_of_bytes nlrpn_b in
  assert (nlrpnn = U64.v nlrpn);
  let nlrpn' = U64.uint_to_t nlrpnn in
  assert (nlrpn' = U64.(enc_nl +^ r));
  assert (U64.(nlrpn' -^ enc_nl) = r);
  n

let create_nonce #i #alg iv nl rpn =
  create_nonce_aux #i #alg iv nl rpn


val create_nonce_inv
  (#i:I.id)
  (#alg:I.cipherAlg{alg == I.cipherAlg_of_id i})
  (iv: AEAD.iv alg)
  (nl:pnlen)
  (n:nonce i nl) :
  Pure rpn
  (requires 
    (let ll = v (AEAD.ivlen alg) in
    Bytes.fits_in_k_bytes (U128.v iv) ll /\
    (let iv_b = Bytes.bytes_of_int ll (U128.v iv) in
    let enc_nl = encode_nl nl in
    Bytes.fits_in_k_bytes (U128.v n) ll /\
    (let n_b' = Bytes.bytes_of_int ll (U128.v n) in
    let nlrpn_b' = Bytes.xor (AEAD.ivlen alg) n_b' iv_b in
      Bytes.int_of_bytes nlrpn_b' < pow2 64 /\
      Bytes.int_of_bytes nlrpn_b' >= U64.v enc_nl /\
      Bytes.int_of_bytes nlrpn_b' - U64.v enc_nl <= max_ctr))))
  (ensures fun _ -> True)

let create_nonce_inv #i #alg iv nl n =
  let ll = v (AEAD.ivlen alg) in
  assert(Bytes.fits_in_k_bytes (U128.v iv) ll);
  let iv_b = Bytes.bytes_of_int ll (U128.v iv) in 
  let enc_nl = encode_nl nl in
  assert(Bytes.fits_in_k_bytes (U128.v n) ll);
  let n_b' = Bytes.bytes_of_int ll (U128.v n) in
  let nlrpn_b' = Bytes.xor (AEAD.ivlen alg) n_b' iv_b in
  assert(Bytes.int_of_bytes nlrpn_b' < pow2 64 /\ Bytes.int_of_bytes nlrpn_b' >= U64.v enc_nl);
  U64.(uint_to_t (Bytes.int_of_bytes nlrpn_b') -^ enc_nl)

val create_nonce_inv_lemma 
  (#i:I.id)
  (#alg:I.cipherAlg{alg == I.cipherAlg_of_id i})
  (iv: AEAD.iv alg)
  (nl:pnlen)
  (r:rpn) :
  Lemma
  (requires True)
  (ensures create_nonce_inv #i #alg iv nl (create_nonce #i #alg iv nl r) = r)

let create_nonce_inv_lemma #i #alg iv nl r = ()
  


type aead_info (i:I.id) = u:(AEAD.info i){u.AEAD.plain == aead_plain_pkg /\ u.AEAD.nonce == aead_nonce_pkg}



let increases_u64 (x:U64.t) (y:U64.t)  = increases (U64.v x) (U64.v y)
let increases_u32 (x:U32.t) (y:U32.t)  = increases (U32.v x) (U32.v y)

let increases_orpn (x:option rpn) (y:option rpn) =
  match x,y with
  | None, _ -> True
  | Some _, None -> False
  | Some xx, Some yy -> increases_u64 xx yy
  
let rpn_ref (r:erid) (i:I.id) : Tot Type0 =
  m_rref r rpn increases_u64

//let orpn_ref (r:erid) (i:I.id) : Tot Type0 =
//  m_rref r (option rpn) increases_orpn

noeq type stream_writer (i:I.id) (j:I.id) =
  | Stream_writer:
    #region: rgn ->
    aead: AEAD.aead_writer i
      {let u:AEAD.info i = AEAD.wgetinfo aead in
        u.AEAD.plain == aead_plain_pkg /\
        u.AEAD.nonce == aead_nonce_pkg /\
        Set.disjoint (Set.singleton region) (AEAD.wfootprint aead) /\
        Set.disjoint (Set.singleton region) (AEAD.shared_footprint)} ->
    pne: PNE.pne_state j npn_pkg
      {Set.disjoint (Set.singleton region) (Set.singleton (PNE.footprint pne))/\
      Set.disjoint (AEAD.wfootprint aead) (Set.singleton (PNE.footprint pne)) /\
      Set.disjoint (AEAD.shared_footprint) (Set.singleton (PNE.footprint pne))} ->
    iv: AEAD.iv (I.cipherAlg_of_id i) ->
    ctr: rpn_ref region i ->
    stream_writer i j

noeq type stream_reader (#i:I.id) (#j:I.id) (w:stream_writer i j) =
  | Stream_reader:
    #region: rgn ->
    aead: AEAD.aead_reader (Stream_writer?.aead w)
      {let u:AEAD.info i = AEAD.rgetinfo aead in
        u.AEAD.plain == aead_plain_pkg /\
        u.AEAD.nonce == aead_nonce_pkg /\
        Set.disjoint (Set.singleton region) (AEAD.wfootprint (Stream_writer?.aead w)) /\
        Set.disjoint (Set.singleton region) (AEAD.rfootprint aead) /\
        Set.disjoint (Set.singleton region) (AEAD.shared_footprint) /\
        Set.disjoint (Set.singleton region) (Set.singleton (Stream_writer?.region w)) /\
        Set.disjoint (Set.singleton region) (Set.singleton (PNE.footprint (Stream_writer?.pne w))) /\
        Set.disjoint (Set.singleton (Stream_writer?.region w)) (AEAD.rfootprint aead)} ->
    iv: AEAD.iv (I.cipherAlg_of_id i){iv = w.iv} ->
    pne: PNE.pne_state j npn_pkg
      {pne == w.pne /\
      Set.disjoint (AEAD.rfootprint aead) (Set.singleton (PNE.footprint pne))}  ->
    expected_pn: rpn_ref region i ->
    stream_reader w

let writer_aead_state #i #j w = Stream_writer?.aead w

let reader_aead_state #i #j #w r = Stream_reader?.aead r

let writer_pne_state #i #j w = Stream_writer?.pne w

let reader_pne_state #i #j #w r = Stream_reader?.pne r


#reset-options "--z3rlimit 50"
let invariant (#i:I.id) (#j:I.id) (w:stream_writer i j) (h:mem) =
  let iv = Stream_writer?.iv w in
  let alg = I.cipherAlg_of_aeadAlg
    ((AEAD.wgetinfo (Stream_writer?.aead w)).AEAD.alg) in
  AEAD.winvariant (Stream_writer?.aead w) h /\
  (if safeId i then
    let wc = sel h (Stream_writer?.ctr w) in
    let wlg = AEAD.wlog (Stream_writer?.aead w) h in
    UInt64.v wc = Seq.length wlg /\
    (forall (k:nat). (k < Seq.length wlg) ==>
      (let e = Seq.index wlg k in
      let rpn:rpn = U64.uint_to_t k in    
      AEAD.Entry?.n e = create_nonce #i #alg iv (AEAD.Entry?.tag e) rpn)) /\
    (if safePNE j then 
      begin
      let pne = Stream_writer?.pne w in
      let pnelg = PNE.table pne h in
      (forall (k:nat). (k < Seq.length wlg) ==>
        (let e = Seq.index wlg k in
        let rpn:rpn = U64.uint_to_t k in
        (exists (e':PNE.entry j npn_pkg).
          (Seq.mem e' pnelg /\ 
          PNE.Entry?.s e' = PNE.sample_cipher (AEAD.Entry?.c e) /\
          PNE.Entry?.l e' = AEAD.Entry?.tag e /\
          PNE.Entry?.n e' = npn_encode j rpn (AEAD.Entry?.tag e)))))
        end
      else True)
    else True)


#reset-options "--z3rlimit 10"
let rinvariant (#i:I.id) (#j:I.id) (#w:stream_writer i j) (r:stream_reader w) (h:mem) =
//  let wc = sel h (Stream_writer?.ctr w) in
//  let pnlg = sel h (Stream_reader?.pnlg r) in
  AEAD.winvariant (Stream_writer?.aead w) h ///\
  //(safeId i ==> (forall (n:pn j). Seq.mem n pnlg ==> pn_as_nat j n < v wc))


let wctrT #i #j w h =
  U64.v (sel h (Stream_writer?.ctr w))

let wctr #i #j w =
  !(Stream_writer?.ctr w)

let writer_iv #i #j w = Stream_writer?.iv w

let reader_iv #i #j #w r = Stream_reader?.iv r

let expected_pnT #i #j #w r h = sel h (Stream_reader?.expected_pn r)

let expected_pn #i #j #w r = !(Stream_reader?.expected_pn r)

#reset-options "--z3rlimit 50"

let shared_footprint #i #j w = AEAD.shared_footprint

let footprint #i #j w =
  assume False;
  Set.union 
    (AEAD.wfootprint (Stream_writer?.aead w))
    (Set.union 
      (Set.singleton (PNE.footprint (Stream_writer?.pne w)))
      (Set.singleton (Stream_writer?.region w)))
 

let rfootprint #i #j #w r =
  assume False;
  Set.union 
    (AEAD.rfootprint (Stream_reader?.aead r))
    (Set.union
      (AEAD.wfootprint (Stream_writer?.aead w))
      (Set.union 
        (Set.singleton (PNE.footprint (Stream_reader?.pne r)))
        (Set.union
          (Set.singleton (Stream_reader?.region r))
          (Set.singleton (Stream_writer?.region w)))))

let frame_invariant #i #j w h0 ri h1 =
  let aw = Stream_writer?.aead w in
  let ps = Stream_writer?.pne w in
  let ctr = Stream_writer?.ctr w in
  AEAD.wframe_invariant aw h0 ri h1;
  if safeId i then AEAD.frame_log aw (AEAD.wlog aw h0) h0 ri h1;
  if safePNE j then PNE.frame_table ps (PNE.table ps h0) h0 (Set.singleton ri) h1;
  assume (ri <> (frameOf ctr) ==> sel h0  ctr = sel h1 ctr)


let rframe_invariant #i #j #w r h0 ri h1 = 
  let aw = Stream_writer?.aead w in
  AEAD.wframe_invariant aw h0 ri h1

let wframe_log #i #j w l h0 ri h1 =
  let aw = Stream_writer?.aead w in
  AEAD.frame_log aw (AEAD.wlog aw h0) h0 ri h1

let rframe_log #i #j #w r l h0 ri h1 =
  let aw = Stream_writer?.aead w in
  AEAD.frame_log aw (AEAD.wlog aw h0) h0 ri h1

let wframe_pnlog #i #j w l h0 ri h1 =
  let ps = Stream_writer?.pne w in
  PNE.frame_table ps (PNE.table ps h0) h0 (Set.singleton ri) h1

let rframe_pnlog #i #j #w r l h0 ri h1 =
  let ps = Stream_writer?.pne w in
  PNE.frame_table ps (PNE.table ps h0) h0 (Set.singleton ri) h1

let random_iv (alg:I.cipherAlg) :
  ST (AEAD.iv alg) (requires fun _ -> True) (ensures fun h0 _ h1 -> h0 == h1) =
  let ivlen = AEAD.ivlen alg in
  let b = CoreCrypto.random32 ivlen in
  let iv_nat = Bytes.int_of_bytes b in
 // assert (length b = (v ivlen));
//  assert (fits_in_k_bytes iv_nat (v ivlen));
//  assert (UInt.fits iv_nat (8 * (v ivlen)));
//  assert (iv_nat < pow2 (8 * (v ivlen)));
  Math.Lemmas.pow2_lt_compat 128 (FStar.Mul.(8 * (v ivlen)));
  let iv = U128.uint_to_t iv_nat in
  iv
  
let aead_info_of_info (#i:I.id) (#j:I.id) (u:info i j) : AEAD.info i =
  {AEAD.alg= u.alg; AEAD.prf_rgn=u.shared; AEAD.log_rgn=u.local; AEAD.plain=aead_plain_pkg; AEAD.nonce=aead_nonce_pkg}

assume val aead_frame_log': #i:I.id -> w:AEAD.aead_writer i ->
  l:Seq.seq (AEAD.entry i (AEAD.wgetinfo w)) -> h0:mem -> s:Set.set rid -> h1:mem ->
  Lemma
    (requires
      safeId i /\
      modifies s h0 h1 /\
      Set.disjoint s (AEAD.wfootprint w) /\
      AEAD.wlog w h0 == l)
    (ensures AEAD.wlog w h1 == l)

assume val aead_frame_invariant': #i:I.id -> w:AEAD.aead_writer i -> h0:mem -> s:Set.set rid -> h1:mem ->
  Lemma
  (requires
    (AEAD.winvariant w h0 /\
    Set.disjoint s (AEAD.wfootprint w) /\
    Set.disjoint s (AEAD.shared_footprint) /\
    modifies s h0 h1 ))
  (ensures AEAD.winvariant w h1)

let create i j u =
  let aw = AEAD.gen i (aead_info_of_info u) in
  let ha = get() in
  let pne = PNE.create j npn_pkg in
  let hb = get() in
  let rr = new_region u.parent in
  let alg = I.cipherAlg_of_aeadAlg u.alg in
  let iv:AEAD.iv (I.cipherAlg_of_id i) = random_iv alg in
  let ctr: rpn_ref rr i = ralloc #rpn #increases_u64 rr (rpn_of_nat 0) in
  let hc = get() in
  aead_frame_invariant' aw ha Set.empty hc;
  if safeId i then aead_frame_log' aw Seq.empty ha Set.empty hc;
  if safePNE j then PNE.frame_table pne Seq.empty hb Set.empty hc;
  assume (Set.disjoint (AEAD.wfootprint aw) (Set.singleton (PNE.footprint pne)));
  assume (Set.disjoint (AEAD.shared_footprint) (Set.singleton (PNE.footprint pne)));
  assume (Set.disjoint (Set.singleton rr) (Set.singleton (PNE.footprint pne)));
  Stream_writer #i #j #rr aw pne iv ctr


let createReader parent #i #j w =
  let ha = get() in
  let aw = Stream_writer?.aead w in
  let ar = AEAD.genReader aw in
  let pne = Stream_writer?.pne w in
  let rr = new_region parent in
  let iv = Stream_writer?.iv w in
  let hrpn = ralloc #rpn #increases_u64 rr (U64.uint_to_t 0) in
  let hb = get() in  
  assume ((Stream_writer?.region w) <> (AEAD.rgetinfo ar).AEAD.prf_rgn); 
  assume (Set.disjoint (AEAD.rfootprint ar) (Set.singleton (PNE.footprint pne)));
  assume (~ (Set.mem rr 
    (Set.union 
      (Set.union 
        (Set.union 
          (Set.union (AEAD.wfootprint aw) (AEAD.rfootprint ar))
          (Set.singleton (PNE.footprint pne)))
        (Set.singleton (Stream_writer?.region w)))
      (AEAD.shared_footprint))));
  aead_frame_invariant' aw ha Set.empty hb;
  Stream_reader #i #j #w #rr ar iv pne hrpn


val create_nonce_inj
  (#i:I.id)
  (#alg:I.cipherAlg{alg == I.cipherAlg_of_id i})
  (iv:AEAD.iv alg)
  (nl:pnlen)
  (r:rpn)
  (r':rpn) :
  Lemma
  (requires create_nonce #i #alg iv nl r = create_nonce #i #alg iv nl r')
  (ensures r = r')

let create_nonce_inj #i #alg iv nl r r' =
  let n = create_nonce #i #alg iv nl r in
  let n' = create_nonce #i #alg iv nl r' in
  assert (create_nonce_inv #i #alg iv nl n = create_nonce_inv #i #alg iv nl n');
  create_nonce_inv_lemma #i #alg iv nl r;
  create_nonce_inv_lemma #i #alg iv nl r'

let create_nonce_inj' i alg iv nl r r' :
  Lemma ((create_nonce #i #alg iv nl r = create_nonce #i #alg iv nl r') ==> r = r') =
(FStar.Classical.move_requires (create_nonce_inj #i #alg iv nl r) r')

let create_nonce_inj'' i alg iv nl r :
  Lemma (forall (r':rpn). (create_nonce #i #alg iv nl r = create_nonce #i #alg iv nl r') ==> r = r') =  
 FStar.Classical.forall_intro (fun r' -> create_nonce_inj' i alg iv nl r r')


val lem_fresh (i:I.id) (j:I.id) (w:stream_writer i j) (alg:I.cipherAlg{alg == I.cipherAlg_of_id i})
(nl:pnlen) (h:mem) :
  Lemma
  (requires safeId i /\ wincrementable w h /\ invariant w h)
  (ensures 
   (let iv = Stream_writer?.iv w in
    let aw = Stream_writer?.aead w in
    AEAD.fresh_nonce #i aw #nl (create_nonce #i #alg iv nl (rpn_of_nat (wctrT w h))) h))


let lem_fresh i j w alg nl h = 
  let iv = Stream_writer?.iv w in
  let aw = Stream_writer?.aead w in
  let r = rpn_of_nat (wctrT w h) in
  let n' = create_nonce #i #alg iv nl r in
  let lg = AEAD.wlog aw h in
  let ps = Stream_writer?.pne w in
  let pnelg = PNE.table ps h in
  assert (invariant w h);
  assert (forall (k:nat). (k < Seq.length lg ==> 
    (let e' = Seq.index lg k in
    let rk:rpn = U64.uint_to_t k in
    AEAD.Entry?.n e' = create_nonce #i #alg iv (AEAD.Entry?.tag e') rk)));
  match AEAD.wentry_for_nonce #i aw #nl n' h with
  | None -> ()
  | Some e -> 
    lemma_find_l_contains (AEAD.nonce_filter #i #aw #nl n') lg;
    Seq.contains_elim lg e; 
    assert (exists (k:nat). k < Seq.length lg /\ Seq.index lg k = e  /\
      (let rk = rpn_of_nat k in
        n' = create_nonce #i #alg iv nl rk));
    create_nonce_inj'' i alg iv nl r
 

#reset-options "--initial_fuel 1 --max_fuel 1 --z3rlimit 80"

let encrypt #i #j w nl l p =
  let ha = get() in
  let aw : AEAD.aead_writer i = writer_aead_state w in
  let ps : PNE.pne_state j npn_pkg = writer_pne_state w in
  let ctr : rpn_ref (Stream_writer?.region w) i = Stream_writer?.ctr w in
  let iv = writer_iv w in
  let alg = I.cipherAlg_of_aeadAlg ((AEAD.wgetinfo aw).AEAD.alg) in
  let rpn' = !ctr in
  assert (rpn' = rpn_of_nat (wctrT w ha));
  let npn : npn j nl = npn_encode j rpn' nl in
  let n = create_nonce #i #alg iv nl rpn' in
  let ad = Bytes.empty_bytes in
 
  if safeId i then lem_fresh i j w alg nl ha;
  let c : cipher i l = AEAD.encrypt i aw #nl n ad l p in
  let cc : PNE.cipher = c in
  let hb = get() in
  assume (PNE.fresh_sample (PNE.sample_cipher c) ps hb);
  let ne = PNE.encrypt #j #npn_pkg ps #nl npn c in
  let hc = get() in
  assert (modifies (Set.singleton (PNE.footprint ps)) hb hc);
  assert (Set.disjoint (Set.singleton (Stream_writer?.region w)) (Set.singleton (PNE.footprint ps)));
  assert (frameOf ctr = Stream_writer?.region w);
  assume (
    (Set.disjoint (Set.singleton (Stream_writer?.region w)) (Set.singleton (PNE.footprint ps)) /\
    frameOf ctr = Stream_writer?.region w) ==>
    (Set.disjoint (Set.singleton (frameOf ctr)) (Set.singleton (PNE.footprint ps))));
  assert (Set.disjoint (Set.singleton (frameOf ctr)) (Set.singleton (PNE.footprint ps)));
  assert (sel hb ctr == sel hc ctr);
  ctr := U64.(!ctr +^ (uint_to_t 1));
  let hd = get() in  
  assert (modifies (Set.singleton (Stream_writer?.region w)) hc hd);
  assert (modifies (Set.union (AEAD.wfootprint aw) AEAD.shared_footprint) ha hb);
  aead_frame_invariant' aw hb (Set.singleton (PNE.footprint ps)) hc;
  aead_frame_invariant' aw hc (Set.singleton (Stream_writer?.region w)) hd;
//  assume (invariant w hd);
  if safeId i then
    begin
     aead_frame_log' aw (AEAD.wlog aw hb) hb (Set.singleton (PNE.footprint ps)) hc;
     aead_frame_log' aw (AEAD.wlog aw hc) hc (Set.singleton (Stream_writer?.region w)) hd;
     assert (AEAD.wlog aw hd == Seq.snoc (AEAD.wlog aw ha) (AEAD.Entry #i #(AEAD.wgetinfo aw) #nl n ad p c));
     assert (
       let wlg = AEAD.wlog (Stream_writer?.aead w) hd in
       (forall (k:nat). (k < wctrT w ha) ==>
         (let e = Seq.index wlg k in
         let rpn':rpn = U64.uint_to_t k in    
         AEAD.Entry?.n e = create_nonce #i #alg iv (AEAD.Entry?.tag e) rpn')));
     assert (
       let wlg = AEAD.wlog (Stream_writer?.aead w) hd in
       let k = wctrT w ha in
       let e = Seq.index wlg k in
       let rpn':rpn = U64.uint_to_t k in    
       AEAD.Entry?.n e = create_nonce #i #alg iv (AEAD.Entry?.tag e) rpn');
     assert (
       let wlg = AEAD.wlog (Stream_writer?.aead w) hd in
       (forall (k:nat). (k <= wctrT w ha) ==>
         (let e = Seq.index wlg k in
         let rpn':rpn = U64.uint_to_t k in    
         AEAD.Entry?.n e = create_nonce #i #alg iv (AEAD.Entry?.tag e) rpn')));
     if safePNE j then
       begin
         let s = PNE.sample_cipher c in
         PNE.frame_table ps (PNE.table ps ha) ha (Set.union (AEAD.wfootprint aw) AEAD.shared_footprint) hb; 
         PNE.frame_table ps (PNE.table ps hc) hc (Set.singleton (Stream_writer?.region w)) hd; 
         assert (PNE.table ps hc == Seq.snoc (PNE.table ps hb) (PNE.Entry #j #npn_pkg s #nl ne npn));
         assert (PNE.table ps hd == Seq.snoc (PNE.table ps ha) (PNE.Entry #j #npn_pkg s #nl ne npn));
         assert (UInt64.v (sel hd ctr) = Seq.length (AEAD.wlog aw hd));
         assume (
           let wlg = AEAD.wlog aw hd in
           let pnelg = PNE.table ps hd in
          (forall (k:nat). (k < Seq.length wlg) ==>
          (let e = Seq.index wlg k in
            let rpn'':rpn = U64.uint_to_t k in
            (exists (e':PNE.entry j npn_pkg).
              (Seq.mem e' pnelg /\ 
              PNE.Entry?.s e' = PNE.sample_cipher (AEAD.Entry?.c e) /\
              PNE.Entry?.l e' = AEAD.Entry?.tag e /\
              PNE.Entry?.n e' = npn_encode j rpn'' (AEAD.Entry?.tag e))))))
       end
    end;
  (ne,c)

