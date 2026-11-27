# Backups and restore guide

This explains, in plain words, how Nirva's data is backed up and how to get it
back if something goes wrong.

## What is backed up

Every night at **2:00 AM India time**, GitHub makes a full copy of each
Supabase database:

| Backup name | Database | Used by |
|---|---|---|
| `nirva-sarvam-...` | Sarvam Riya database (`nirva-riya-sarvam-test`) | Riya on Sarvam and the Sarvam dashboard |
| `nirva-main-...` | Main dashboard database | nirva-dashboard-staging.vercel.app |

Each copy holds everything inside the database: patients, appointments,
doctors, schedules, leave, callbacks, call logs, staff logins and roles, and
all the rules and functions.

Each copy is **locked with a password** (a `.7z` file with AES-256 encryption).
This matters because the repository is public and the backups contain patient
data. Without the password, nobody can open them.

Copies are kept for **30 days**, then GitHub deletes them automatically. So at
any time you have the last 30 nights.

**Not inside the database backup** (these are already saved elsewhere):
- Riya's prompt, Edge Function code and setup SQL: saved in this GitHub
  repository in the `riya-tests/` folder (currently on the branch
  `claude/project-thread-gxs60j`), and in the project files.
- Secrets and API keys: never backed up here on purpose. Keep them in your
  password manager.

## One-time setup (Pratham does this once)

You add three "secrets" to GitHub. A secret is a private value that GitHub
keeps hidden, even from people who can see the code.

### Step 1: Get the database connection strings

Do this for the Sarvam project, then again for the main dashboard project.

1. Open the project on supabase.com.
2. Click the green **Connect** button at the top.
3. Choose **Session pooler** (not "Direct connection", because GitHub cannot
   reach that one).
4. Copy the line that starts with `postgresql://postgres.`
5. It contains `[YOUR-PASSWORD]`. Replace that with the database password.
   If you don't remember it: Project Settings > Database > **Reset database
   password**, click Generate, and copy it. (A generated password has only
   letters and numbers, which is what you want here.)

It should look like:
`postgresql://postgres.abcdefgh:MyPassword123@aws-0-ap-south-1.pooler.supabase.com:5432/postgres`

### Step 2: Choose a backup password

Make a long password, for example four random words joined with dashes.
**Save it in your password manager now.** If you lose it, the backups can
never be opened, by anyone, including you.

### Step 3: Add the secrets to GitHub

1. Open the repository on GitHub.
2. Go to **Settings > Secrets and variables > Actions**.
3. Click **New repository secret** three times and add:

| Name | Value |
|---|---|
| `BACKUP_PASSWORD` | the password from Step 2 |
| `SARVAM_DB_URL` | the Sarvam connection string from Step 1 |
| `MAIN_DB_URL` | the main dashboard connection string from Step 1 |

If you leave out one database, the backup still runs for the others and shows
a yellow warning.

### Step 4: Check it works

1. Go to the **Actions** tab and click **Daily database backup**.
2. Click **Run workflow**, then the green **Run workflow** button.
3. After 2 to 3 minutes, each line should show a green tick.

If something fails, GitHub emails you. Send the email or the link to Claude.

## How to download a backup

1. GitHub > **Actions** tab > **Daily database backup**.
2. Click the run for the date you want.
3. Scroll to **Artifacts** and click the backup name. A `.zip` downloads.
4. Open the zip. Inside is a `.7z` file.
5. Open the `.7z` with **Keka** or **The Unarchiver** (both free on the Mac
   App Store). Type the backup password.
6. You get a folder with:
   - `README.txt`: when it was taken, and how many rows each table had
   - `roles.sql`, `schema.sql`, `data.sql`: the actual backup

Tip: `README.txt` is a quick way to check a backup has real data in it.

## How to restore

Restoring puts a backup into a database. The safest way is to restore into a
**new, empty Supabase project**, check it, and then point Riya and the
dashboard to it. Never restore on top of a live database that still has data,
because the two will clash.

The easiest path is to ask Claude: "Restore the backup from <date> into a new
Supabase project." Claude will walk you through it.

What happens in a restore (for whoever does it):

1. Create a new Supabase project (Mumbai region). Copy its Session pooler
   connection string as in Step 1 above.
2. On the Mac, install the database tool once: `brew install libpq` then
   `brew link --force libpq`.
3. In Terminal, inside the unlocked backup folder, run:

   ```bash
   psql \
     --single-transaction \
     --variable ON_ERROR_STOP=1 \
     --file roles.sql \
     --file schema.sql \
     --command 'SET session_replication_role = replica' \
     --file data.sql \
     --dbname "PASTE-NEW-CONNECTION-STRING-HERE"
   ```

   `--single-transaction` means it is all or nothing: if anything fails,
   nothing is half-written.
4. Check: open the new project's Table Editor and compare row counts with
   `README.txt`.
5. Check the scheduled jobs (Database > Cron) are there. If not, re-run the
   cron SQL from `riya-tests/supabase/`.
6. Deploy the Edge Functions to the new project with
   `riya-tests/deploy-functions.sh`, and set their secrets again.
7. Update the new project URL and key in the dashboard's `config.js`, and the
   tool URLs in the Sarvam agent. Push and redeploy on Vercel.

## Good habits

- **Test a restore once a month** into a spare free Supabase project. A backup
  you have never restored is a backup you are hoping works.
- GitHub turns off scheduled jobs in a public repository after **60 days with
  no new commits**. It emails you first. If you get that email, open the
  Actions tab and click **Enable workflow**.
- Free Supabase projects pause after a week without use. A paused project
  cannot be backed up, and the run fails and emails you.
