; ModuleID = 'test-primops.bc'
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v64:64:64-v128:128:128-a0:0:64-s0:64:64-f80:128:128-n8:16:32:64"
target triple = "x86_64-apple-darwin10.0.0"

define i32 @int32_add(i32 %a0, i32 %a1) {
  %r0 = add i32 %a0, %a1
  ret i32 %r0
}

define i32 @int32_mul(i32 %a2, i32 %a3) {
  %r0 = mul i32 %a2, %a3
  ret i32 %r0
}

define i32 @int32_square(i32 %a4) {
  %r0 = call i32 @int32_mul(i32 %a4, i32 %a4)
  ret i32 %r0
}

define i32 @int32_muladd(i32 %a5, i32 %a6) {
  %r0 = call i32 @int32_add(i32 %a5, i32 %a6)
  %r1 = call i32 @int32_square(i32 %r0)
  ret i32 %r1
}

define i32 @factorial(i32 %a0) {
entry:
  br label %test

test:                                             ; preds = %incr, %entry
  %r0 = phi i32 [ %a0, %entry ], [ %r4, %incr ]
  %r1 = phi i32 [ 1, %entry ], [ %r3, %incr ]
  %r2 = icmp ule i32 %r0, 1
  br i1 %r2, label %exit, label %incr

incr:                                             ; preds = %test
  %r3 = mul i32 %r1, %r0
  %r4 = sub i32 %r0, 1
  br label %test

exit:                                             ; preds = %test
  ret i32 %r1
}

define void @ptrarg(i32* %p) nounwind ssp {
  %1 = alloca i32*, align 8
  store i32* %p, i32** %1, align 8
  %2 = load i32** %1, align 8
  store i32 42, i32* %2
  ret void
}
