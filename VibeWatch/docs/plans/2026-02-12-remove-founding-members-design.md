# Remove Founding Members Program - Design Document

**Date**: 2026-02-12
**Status**: Approved
**Author**: Design validated with product owner

## Overview

Complete removal of the Founding Members promotional program from VibeWatch. The program has no active users and has been replaced by new standard pricing (€4.99/month, €39.99/year) configured in App Store Connect.

## Scope

### Files to Delete (2)
- `VibeWatchApp/Core/Services/FoundingMemberService.swift` - entire service (107 lines)
- Any analytics events specific to founding members

### Files to Modify (~30)
- **Swift files**: ProPaywallView, DailyLimitPaywallView, PricingCard, RevenueCatService, AnalyticsService, AppConstants
- **Localization files**: 22 language files (remove `paywall.foundingMember` key)
- **Backend**: revenuecat-webhook/index.ts, new database migration

### Database Changes
- Drop `is_founding_member` column from profiles table
- Update `handle_new_user()` trigger to remove column reference

## Key Principles

1. **Complete removal** - no remnants of founding member logic
2. **Update pricing** - remove hardcoded fallback values, rely on RevenueCat's localized pricing
3. **Simplify offerings** - only use "default" offering, remove "founding_member" offering
4. **Clean product IDs** - remove all founding-specific product ID references
5. **Preserve history** - commit changes with clear message documenting the removal

## Detailed Changes

### Section 1: Core Services

#### Delete FoundingMemberService.swift
- Remove the entire file (107 lines)
- Remove all import/reference statements across the app

#### AppConstants.swift
Remove founding member offering constant:
```swift
enum RevenueCat {
    static let proEntitlementID = "StartingVibe Pro"

    enum Offerings {
        // DELETE: static let foundingMember = "founding_member"
        static let standard = "default"
    }
}
```

#### RevenueCatService.swift
Remove promo refresh call:
```swift
func refreshOfferings(debug: Bool = true) async {
    // ... existing code ...
    self.currentOfferingID = offerings.current?.identifier
    // DELETE: FoundingMemberService.shared.refreshPromoStatus()
}
```

#### AnalyticsService.swift
- Find `logSubscriptionPurchased` method
- Remove `isFoundingMember` parameter
- Remove any founding member event logging

### Section 2: Paywall Views

#### ProPaywallView.swift (Major cleanup)

Remove:
- Line 12: `@ObservedObject private var foundingService = FoundingMemberService.shared`
- Lines 71-79: entire `promoCountdown` conditional blocks
- Lines 264-277: `promoCountdown` view definition
- Lines 476-487: founding member product IDs from `monthlyPriorityIds` and `annualPriorityIds` arrays
- Lines 505-510: founding member offering logic
- Lines 684-687: `FoundingMemberService.shared.markAsFoundingMember()` call after purchase
- Line 693: remove `isFoundingMember` parameter from analytics call
- Lines 740-743: `FoundingMemberService.shared.markAsFoundingMember()` call after restore
- Lines 281, 288, 295: Remove hardcoded fallback prices - return `nil` if package unavailable

#### DailyLimitPaywallView.swift
- Line 59: Remove `@ObservedObject private var foundingService`
- Lines 99-100: Remove conditional promo countdown banner

#### PricingCard.swift
- Lines 92-108: Update preview examples to use generic prices or remove specific currency symbols

### Section 3: Localization

Remove `"paywall.foundingMember"` key from all 22 language files:
- en.lproj/Localizable.strings (line 319)
- pl, hi, da, el, ja, fi, de, it, es, fr, no, ko, nl, zh, tr, sv, ru, pt, nb

### Section 4: Backend Changes

#### Webhook (supabase/functions/revenuecat-webhook/index.ts)

Remove:
- Lines 60-62: founding member check in `handleInitialPurchase`
- Lines 66-78: entire `markAsFoundingMember` function

#### Database Migration

Create: `supabase/supabase/migrations/YYYYMMDD_remove_founding_members.sql`

```sql
-- Remove founding member column from profiles
ALTER TABLE public.profiles
DROP COLUMN IF EXISTS is_founding_member;

-- Update trigger function to remove founding member reference
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (
    id,
    email,
    display_name,
    avatar_url,
    created_at,
    updated_at,
    daily_clips_watched
  )
  VALUES (
    new.id,
    new.email,
    COALESCE(new.raw_user_meta_data->>'display_name', new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name'),
    new.raw_user_meta_data->>'avatar_url',
    NOW(),
    NOW(),
    0
  )
  ON CONFLICT (id) DO UPDATE
  SET
    email = EXCLUDED.email,
    display_name = COALESCE(EXCLUDED.display_name, public.profiles.display_name),
    avatar_url = COALESCE(EXCLUDED.avatar_url, public.profiles.avatar_url),
    updated_at = NOW();

  RETURN new;
END;
$$;
```

## Implementation Order

1. **Database first** - Run migration to remove column, update trigger
2. **Backend** - Update webhook to remove founding member logic
3. **Swift services** - Delete FoundingMemberService, update RevenueCatService, AnalyticsService, AppConstants
4. **Swift views** - Clean up ProPaywallView, DailyLimitPaywallView, PricingCard
5. **Localization** - Remove strings from all 22 language files
6. **Verification** - Build, test paywall flow, verify RevenueCat offerings

## Testing Strategy

### Build Verification
- Ensure app compiles with zero errors
- No lingering references to FoundingMemberService

### Paywall Testing
- Open paywall, verify no countdown banners appear
- Verify only standard offering is shown
- Check pricing displays correctly from RevenueCat

### Purchase Flow
- Test sandbox purchase with new standard pricing
- Verify purchase completes successfully
- Check that no founding member analytics are sent

### Analytics Check
- Verify purchase events no longer include `isFoundingMember` parameter
- Confirm analytics events are still logged correctly

### Database Check
- Confirm `is_founding_member` column removed from profiles
- Verify trigger function works without the column
- Test new user creation flow

## Commit Message

```
refactor: remove Founding Members program entirely

- Delete FoundingMemberService and all promo countdown logic
- Remove is_founding_member from database schema
- Clean up paywall views (no more promo banners)
- Remove founding member offering and product IDs
- Update webhook to remove founding member tracking
- Remove localization strings across 22 languages

Standard pricing now configured in App Store Connect:
- Monthly: €4.99 (varies by region)
- Annual: €39.99 (varies by region)

No active founding members exist.
```

## Currency Handling Note

Pricing currency is automatically handled by RevenueCat's `storeProduct.localizedPriceString` based on the user's App Store region:
- € for European countries
- $ for US
- £ for UK
- etc.

No hardcoded currency values should be used in the code.
