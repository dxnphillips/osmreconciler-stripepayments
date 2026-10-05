# OSM Stripe Reconciler

A local PowerShell tool for 1st Pelsall. It downloads Stripe payments for a date range so they can be bulk imported and categorised in OSM Accountancy.

**Current stage: setup and exploration.** This version connects to OSM and Stripe, downloads Stripe transactions, and lets you try OSM or Stripe URLs and save the output. It never writes to OSM or Stripe. The import step will be added once we've worked out the OSM finance calls and the matching rules from real data.

## Requirements

* Windows with PowerShell 7.2 or newer. Install it with `winget install Microsoft.PowerShell`.
* The Microsoft `SecretManagement` and `SecretStore` modules. The Setup menu offers to install them for your user only.

## Running it

1. Download `OsmStripeReconciler.ps1` to a folder on your PC.
2. Files downloaded from the internet are blocked by Windows, so unblock it once: `Unblock-File .\OsmStripeReconciler.ps1`
3. Start it from a PowerShell 7 window: `pwsh .\OsmStripeReconciler.ps1`
4. Use the Up and Down arrow keys to move, Enter to select and Esc to go back. Number keys 1 to 9 also jump to an option.

Add `-VerboseLogging` to see the API URLs being called and OSM rate limit information.

## First time setup

Open **Setup** and work down the list.

1. **Install or check secret storage.** This installs the modules if needed and creates an encrypted vault. You'll choose a vault password, and you'll be asked for it again when the vault locks after a period of inactivity.
2. **Set OSM app details.**
   * In OSM go to Settings, My Account Details, Developer Tools and create a new OAuth application for this tool. A separate app from the WhatsApp one keeps the permissions apart.
   * Set its redirect URI to `http://localhost:53682/callback`. The script listens on that address on your own PC only, so the login completes automatically. If OSM won't accept an `http://localhost` address, use `https://localhost/callback` instead, and the script will ask you to paste the browser address back after logging in.
   * Enter the client ID, the redirect URI, the scope (we'll confirm the finance scope together), and the client secret. The secret is typed hidden and goes straight into the encrypted vault.
3. **Connect to OSM.** Your browser opens at the OSM login. After you click Authorise, the script checks the returned `state` value to guard against forged logins, swaps the code for tokens, and saves the refresh token in the vault. OSM rotates the refresh token, and the script saves each new one automatically.
4. **Set Stripe restricted key.** In the Stripe Dashboard go to Developers, API keys, Create restricted key. Give it **Read** access only to the resources you need (for example Balance, Balance transaction sources, Charges and Payouts) and leave everything else as None. The script refuses full secret keys (`sk_`), because those can move money.
5. **Test connections.** This checks that both logins work and lists the OSM sections you can see.

## Main menu

* **Choose date range:** last month, this month so far, any of the last 12 months, or custom dates. Dates are UK time, and both ends are included.
* **Download Stripe transactions for the date range:** saves the full JSON and a flat CSV of balance transactions (payments, fees, refunds and payouts), with the original charge description and metadata included. Shows a summary by type.
* **Try an OSM URL (GET)** and **Try a Stripe URL (GET):** type a path such as `/oauth/resource` or `/v1/payouts?limit=3`. The output is shown on screen and saved to a file. The OSM token is only ever sent to `https://www.onlinescoutmanager.co.uk` and the Stripe key only ever to `https://api.stripe.com`. Any other address is refused.
* **Open output folder:** opens the folder where downloads are saved.

## Where things are stored

| What | Where |
| --- | --- |
| OSM client secret, OSM refresh token, Stripe key | Encrypted SecretStore vault named `OsmStripeReconciler` |
| Client ID, redirect URI, scope | `%APPDATA%\OsmStripeReconciler\config.json` |
| Downloads and API output | `%APPDATA%\OsmStripeReconciler\Output` |

**Remove all saved secrets** in Setup deletes everything from the vault. If you stop using the tool, also revoke the Stripe key in the Stripe Dashboard and remove the OSM app.

## Sharing output for development

The output files contain parents' names, emails and payment details. Before sharing any sample, replace names, emails, card details and addresses with placeholders. Keep the structure, amounts and category IDs so the matching can be worked out.
