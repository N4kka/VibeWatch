/** Shape check only; GoTrue/RLS still performs the cryptographic validation. */
export function hasBearerJWTShape(authorization: string | null): boolean {
  return /^Bearer\s+[^\s.]+\.[^\s.]+\.[^\s.]+$/i.test((authorization ?? '').trim())
}
