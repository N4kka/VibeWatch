#!/bin/bash
# Apply the migration to add country_code, language_code, source_region columns

echo "Applying migration to add clip metadata columns..."

# Read the SQL file
SQL=$(cat supabase/supabase/migrations/20250121000000_add_clip_metadata.sql)

# Apply via Supabase SQL editor (you'll need to run this in the dashboard)
echo ""
echo "================================================================"
echo "MIGRATION SQL - Copy and paste this into Supabase SQL Editor:"
echo "https://supabase.com/dashboard/project/rqhxhkijzhqivljivirq/sql/new"
echo "================================================================"
echo ""
cat supabase/supabase/migrations/20250121000000_add_clip_metadata.sql
echo ""
echo "================================================================"
echo "After running the SQL, restart PostgREST to refresh schema cache:"
echo "Go to: Settings > API > Restart API server"
echo "================================================================"
