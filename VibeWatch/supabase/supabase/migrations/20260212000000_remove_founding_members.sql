BEGIN;

-- Remove Founding Members Program
-- This migration removes the is_founding_member column from profiles
-- and updates the trigger function accordingly.

-- Drop the column
ALTER TABLE public.profiles
DROP COLUMN IF EXISTS is_founding_member;

-- Update trigger function to remove is_founding_member reference
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

-- Verify column is removed
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
    AND table_name = 'profiles'
    AND column_name = 'is_founding_member'
  ) THEN
    RAISE EXCEPTION 'is_founding_member column still exists!';
  END IF;
END $$;

COMMIT;
