export type UserStorageObject = {
  bucket_id: string
  name: string
}

export type StorageRemovalBatch = {
  bucket: string
  names: string[]
}

/** Builds Storage API removal calls without ever mixing buckets or exceeding the API batch cap. */
export function storageRemovalBatches(
  objects: UserStorageObject[],
  batchSize = 100,
): StorageRemovalBatch[] {
  if (!Number.isInteger(batchSize) || batchSize <= 0) {
    throw new RangeError('batchSize must be a positive integer')
  }

  const perBucket = new Map<string, string[]>()
  for (const object of objects) {
    const names = perBucket.get(object.bucket_id) ?? []
    names.push(object.name)
    perBucket.set(object.bucket_id, names)
  }

  const batches: StorageRemovalBatch[] = []
  for (const [bucket, names] of perBucket) {
    for (let offset = 0; offset < names.length; offset += batchSize) {
      batches.push({ bucket, names: names.slice(offset, offset + batchSize) })
    }
  }
  return batches
}
