import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts'
import { hasBearerJWTShape } from './auth.ts'

Deno.test('import-parse auth: manca o è malformato → non sembra un JWT', () => {
  assertEquals(hasBearerJWTShape(null), false)
  assertEquals(hasBearerJWTShape(''), false)
  assertEquals(hasBearerJWTShape('Bearer'), false)
  assertEquals(hasBearerJWTShape('Bearer opaque-token'), false)
  assertEquals(hasBearerJWTShape('Basic aaa.bbb.ccc'), false)
  assertEquals(hasBearerJWTShape('Bearer aaa..ccc'), false)
})

Deno.test('import-parse auth: accetta solo la forma Bearer header.payload.signature', () => {
  assertEquals(hasBearerJWTShape('Bearer aaa.bbb.ccc'), true)
  assertEquals(hasBearerJWTShape('bearer aaa.bbb.ccc'), true)
  assertEquals(hasBearerJWTShape('Bearer   aaa.bbb.ccc'), true)
})
