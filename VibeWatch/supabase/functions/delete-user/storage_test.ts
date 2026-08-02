import { assertEquals, assertThrows } from 'https://deno.land/std@0.224.0/assert/mod.ts'
import { storageRemovalBatches } from './storage.ts'

Deno.test('delete-user storage: raggruppa per bucket e rispetta il limite API di 100', () => {
  const objects = [
    ...Array.from({ length: 101 }, (_, index) => ({
      bucket_id: 'imports',
      name: `user/export-${index}.zip`,
    })),
    { bucket_id: 'avatars', name: 'device/avatar.jpg' },
  ]

  const batches = storageRemovalBatches(objects)

  assertEquals(batches.map((batch) => [batch.bucket, batch.names.length]), [
    ['imports', 100],
    ['imports', 1],
    ['avatars', 1],
  ])
  assertEquals(batches[1].names, ['user/export-100.zip'])
})

Deno.test('delete-user storage: un batch size invalido fallisce prima di cancellare', () => {
  assertThrows(
    () => storageRemovalBatches([{ bucket_id: 'imports', name: 'user/export.zip' }], 0),
    RangeError,
  )
})
