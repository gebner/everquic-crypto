module Model.Helpers

let lbytes (l:nat) = b:Seq.seq Lib.IntTypes.uint8 { Seq.length b = l }

let random (l: nat { l < pow2 32 }): lbytes l =
  let open Lib.RandomSequence in
  snd (crypto_random entropy0 l)

let rec lbytes_eq (x y: Seq.seq Lib.IntTypes.uint8): Tot (b:bool { b <==> x `Seq.equal` y }) (decreases (Seq.length x)) =
  if Seq.length x = 0 && Seq.length y = 0 then
    true
  else if Seq.length x = 0 && Seq.length y <> 0 then
    false
  else if Seq.length x <> 0 && Seq.length y = 0 then
    false
  else
    let hx = Seq.head x in
    let hy = Seq.head y in
    let tx = Seq.tail x in
    let ty = Seq.tail y in
    if Lib.RawIntTypes.u8_to_UInt8 hx = Lib.RawIntTypes.u8_to_UInt8 hy && lbytes_eq tx ty then begin
      assert (x `Seq.equal` Seq.append (Seq.create 1 hx) tx);
      assert (y `Seq.equal` Seq.append (Seq.create 1 hy) ty);
      assert (Seq.index (Seq.create 1 hx) 0 == Seq.index (Seq.create 1 hy) 0);
      assert (Seq.create 1 hx `Seq.equal` Seq.create 1 hy);
      true
    end else
      false
