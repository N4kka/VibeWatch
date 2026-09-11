// TMDB's top-level `release_date` is the movie's primary date — the earliest anywhere in the
// world. Announcing on it told an Italian user "Mayday is out now" on 3 Sept for a 4 Sept
// release in Italy. The per-country dates come from `release_dates` (append_to_response).
type ReleaseDates = {
  results?: { iso_3166_1: string; release_dates?: { release_date?: string; type?: number }[] }[]
}

// Type 1 is "Premiere" (festivals, red carpets): not something the user can watch.
const PREMIERE = 1

/// Every day the title comes out in `region` ("yyyy-MM-dd"), premieres excluded.
///
/// All of them, not one: TMDB keeps a postponed date next to the new one (Exit 8 in Italy lists
/// 2026-04-23 and 2026-09-24) and re-releases add more. The radar asks "did one of them happen
/// in the last days", which is right in every case — picking a single date would either announce
/// a postponed release or skip a real one that has a re-release scheduled later.
export function countryReleaseDays(releaseDates: ReleaseDates | undefined, region: string): string[] {
  const country = releaseDates?.results?.find((r) => r.iso_3166_1 === region)
  return (country?.release_dates ?? [])
    .filter((d) => d.type !== PREMIERE && d.release_date)
    .map((d) => d.release_date!.slice(0, 10))
    .sort()
}
