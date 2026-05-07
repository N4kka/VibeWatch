// Import necessary libraries
import { serve } from 'https://deno.land/std@0.131.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// Supabase and RevenueCat secrets (replace with your actual secrets)
const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
const REVENUECAT_WEBHOOK_SECRET = Deno.env.get('REVENUECAT_WEBHOOK_SECRET') ?? ''

// Initialize the Supabase client
const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)

serve(async (req) => {
  const signature = req.headers.get('X-RevenueCat-Signature')
  const body = await req.text()

  // 1. Verify the webhook signature
  if (!signature || !verifySignature(body, signature)) {
    return new Response('Invalid signature', { status: 401 })
  }

  // 2. Handle the event
  const event = JSON.parse(body).event
  const { app_user_id, type, product_id, purchased_at, cancellation_date } = event

  console.log(`Received RevenueCat event: ${type}`)

  switch (type) {
    case 'INITIAL_PURCHASE':
      await handleInitialPurchase(app_user_id, product_id, purchased_at)
      break
    case 'CANCELLATION':
      await handleCancellation(app_user_id, cancellation_date)
      break
    case 'RENEWAL':
    case 'EXPIRATION':
    case 'BILLING_ISSUE':
      // Just log these events for now
      console.log(`Event type: ${type}, User: ${app_user_id}`)
      break
    default:
      console.log(`Unhandled event type: ${type}`)
  }

  return new Response('OK', { status: 200 })
})

// Function to verify the webhook signature
function verifySignature(body: string, signature: string): boolean {
  // In a real implementation, you would use a library like `crypto` to
  // verify the HMAC-SHA256 signature. For now, we will just check if the
  // signature is not empty.
  return signature.length > 0
}

// Function to handle the INITIAL_PURCHASE event
async function handleInitialPurchase(userId: string, productId: string, purchasedAt: string) {
  console.log(`Handling initial purchase for user: ${userId}`)
}

// Function to handle the CANCELLATION event
async function handleCancellation(userId: string, cancellationDate: string) {
  console.log(`Handling cancellation for user: ${userId}`)
  const { data, error } = await supabase
    .from('profiles')
    .update({ subscription_canceled_at: cancellationDate })
    .eq('id', userId)

  if (error) {
    console.error('Error updating subscription_canceled_at:', error)
  } else {
    console.log('Successfully updated subscription_canceled_at for user:', userId)
  }
}
