# Backups and restore guide

This explains, in plain words, how Nirva's data is backed up and how to get it
back if something goes wrong.

## How it works

Every night at **2:00 AM India time**:

1. GitHub borrows a temporary computer for a few minutes.
2. That computer copies each Supabase database.
3. It locks the copy with your backup password.
4. It uploads the locked file to a folder called **Nirva Backups** in **your
   private Google Drive**.
5. It deletes old copies automatically (see "How long copies are kept").
6. The temporary computer is thrown away.

**What is on GitHub:** only the code. That means the HTML and JavaScript
files, the SQL setup files, and the instructions for this nightly job. No
patient data and no backup files are ever saved on GitHub. Nothing goes into
the code or the logs, and nothing is kept for download.

**What is on Google Drive:** the backups, and only you can open them.

| Drive folder | Database | Used by |
|---|---|---|
| `Nirva Backups/sarvam/` | Sarvam Riya database (`nirva-riya-sarvam-test`) | Riya on Sarvam and the Sarvam dashboard |
| `Nirva Backups/main/` | Main dashboard database | nirva-dashboard-staging.vercel.app |

### How long copies are kept

Inside each database folder there are two folders:

| Folder | What is in it | Kept for |
|---|---|---|
| `daily/` | every night's copy | **1 year** (365 copies) |
| `monthly/` | the first copy of each month | **3 years** (36 copies) |

Every copy is a **full** copy of the whole database, not just that day's
changes. So any single file is enough to bring the clinic back to that night,
including old bookings that were changed later.

Why these numbers: India's data law (DPDP Rules 2025, Rule 8) asks for at
least 1 year, and doctors' rules (IMC Regulations 2002) ask clinics to keep
patient records for at least 3 years. The live database keeps the records
themselves. The backups make sure a mistake or a crash can be undone within
those periods. Each copy is small (well under 1 MB today), so all of this fits
comfortably in Drive's free 15 GB.

Each backup holds everything inside the database: patients, appointments,
doctors, schedules, leave, callbacks, call logs, staff logins and roles, and
all the rules and functions.

**Why lock the files when Drive is already private?** If someone ever got
into your Google account, or you shared the folder by mistake, the patient
data would still be unreadable without the password. India's data protection
law (the DPDP Act) expects this kind of care with patient data.

**Not inside the backup** (these are already saved elsewhere):
- Riya's prompt, the Edge Function code and the setup SQL: saved in this
  GitHub repository in the `riya-tests/` folder (currently on the branch
  `claude/project-thread-gxs60j`), and in the project files.
- Secrets and API keys: never backed up, on purpose. Keep them in your
  password manager.

## Where the passwords go

All passwords and keys go into **GitHub Secrets**. A secret is a private
value that GitHub keeps hidden. Nobody can read it back, not even you, and
it never appears in the code or the logs, even though the repository is
public. The nightly job can use it, but nobody can see it.

You add four secrets:

| Secret name | What it is | Where you get it |
|---|---|---|
| `BACKUP_PASSWORD` | the password that locks every backup | you make it up (Step 1) |
| `RCLONE_CONFIG` | permission to upload to your Google Drive | your Mac (Step 2) |
| `SARVAM_DB_URL` | the address and password of the Sarvam database | Supabase (Step 3) |
| `MAIN_DB_URL` | the address and password of the main dashboard database | Supabase (Step 3) |

## One-time setup (about 15 minutes)

### Step 1: Make a backup password

Make a long password, for example four random words joined with dashes, like
`mango-river-lamp-forty`. **Save it in your password manager now.** If you
lose it, nobody can ever open the backups, including you.

### Step 2: Give the backup job permission to use your Google Drive

This uses a free, well-known tool called **rclone**. The permission it gets
is limited to the files it creates itself. It **cannot see or touch any of
your other Drive files.**

1. Open **Terminal** on your Mac.
2. Install rclone. Paste this and press Enter:
   ```bash
   brew install rclone
   ```
3. Connect your Google Drive. Paste this and press Enter:
   ```bash
   rclone config create nirvadrive drive scope=drive.file
   ```
   A browser window opens. Sign in with the Google account where you want
   the backups, then click **Allow**. When the browser says "Success", go
   back to Terminal.
4. Show the permission so you can copy it. Paste this and press Enter:
   ```bash
   rclone config show nirvadrive
   ```
5. Copy **all** the lines it prints, starting from `[nirvadrive]` and ending
   with the line that starts with `token =`. You paste this into GitHub in
   Step 4.

Treat these lines like a password. Don't paste them anywhere except GitHub
Secrets.

### Step 3: Get the two database addresses

Do this once for the Sarvam project, and once for the main dashboard project.

1. Open the project on supabase.com.
2. Click the green **Connect** button at the top.
3. Choose **Session pooler**. Don't choose "Direct connection", because
   GitHub can't reach that one.
4. Copy the line that starts with `postgresql://postgres.`
5. It contains `[YOUR-PASSWORD]`. Replace that with the database password.
   If you don't remember it, go to Project Settings > Database > **Reset
   database password**, click Generate, and copy it. A generated password
   has only letters and numbers, which is what you want here.

It should look like this:
`postgresql://postgres.abcdefgh:MyPassword123@aws-0-ap-south-1.pooler.supabase.com:5432/postgres`

### Step 4: Put the four secrets into GitHub

1. Open the repository on GitHub.
2. Go to **Settings > Secrets and variables > Actions**.
3. Click **New repository secret** and add each one from the table above.
   Type the name exactly as shown, paste the value, and click **Add secret**.

If you leave out one database, the job still backs up the other one and
shows a yellow warning.

### Step 5: Check it works

1. Go to the **Actions** tab and click **Daily database backup**.
2. Click **Run workflow**, then the green **Run workflow** button.
3. After 2 to 3 minutes, both lines should show a green tick.
4. Open Google Drive. You should see **Nirva Backups**, with a `sarvam` and a
   `main` folder. Each has a `daily` and a `monthly` folder with one `.7z`
   file in each.

If something fails, GitHub emails you. Send the email or the link to Claude.

## How to open a backup

1. In Google Drive, open **Nirva Backups**, then `sarvam` or `main`, then
   `daily` (last 12 months) or `monthly` (older, up to 3 years).
2. Download the `.7z` file for the date you want. The date is in the name.
3. Open it with **Keka** or **The Unarchiver** (both free on the Mac App
   Store), and type the backup password.
4. You get a folder with:
   - `README.txt`: when the backup was taken, and how many rows each table had
   - `roles.sql`, `schema.sql`, `data.sql`: the actual backup

Tip: `README.txt` is a quick way to check that a backup has real data in it.

## How to restore

Restoring puts a backup into a database. The safest way is to restore into a
**new, empty Supabase project**, check it, and then point Riya and the
dashboard to it. Never restore on top of a live database that still has data,
because the old and new data will clash.

The easiest path is to ask Claude: "Restore the backup from <date> into a new
Supabase project." Claude will walk you through it.

These are the restore steps, for whoever does it:

1. Create a new Supabase project (Mumbai region). Copy its Session pooler
   connection string, as in Step 3.
2. On the Mac, install the database tool once: `brew install libpq`, then
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

   `--single-transaction` means it's all or nothing. If anything fails,
   nothing is half-written.
4. Check the result. Open the new project's Table Editor and compare the row
   counts with `README.txt`.
5. Check that the scheduled jobs (Database > Cron) are there. If they're
   missing, re-run the cron SQL from `riya-tests/supabase/`.
6. Deploy the Edge Functions to the new project with
   `riya-tests/deploy-functions.sh`, and set their secrets again.
7. Put the new project's URL and key into the dashboard's `config.js`, and
   update the tool URLs in the Sarvam agent. Push the change and redeploy on
   Vercel.

## Good habits and things to know

- **Test a restore once a month** into a spare free Supabase project. Until
  you have restored a backup once, you only hope it works.
- **If you change your Google password**, Google may cancel the Drive
  permission. The next backup then fails and GitHub emails you. Redo Step 2
  and replace the `RCLONE_CONFIG` secret.
- Deleted old copies go to your Drive **Bin** first. Drive empties the Bin
  after 30 days.
- Watch your Drive space once a few clinics are live. Google shows it at the
  bottom left of Drive. If it gets close to 15 GB, a 100 GB Google One plan
  is about ₹130 a month.
- GitHub turns off scheduled jobs in a public repository after **60 days with
  no new commits**. It emails you first. If you get that email, open the
  Actions tab and click **Enable workflow**.
- Free Supabase projects pause after a week without use. A paused project
  can't be backed up, so that night's backup fails and GitHub emails you.
