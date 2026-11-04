JARVIS: a free project tracker for your classroom
=================================================

JARVIS helps a teacher and their students keep track of project-based work.
Students sign in, see what is assigned to them, move it along, and ask
questions. You see the whole class at a glance. It runs on free accounts
that YOU own, so your class data stays with you.

STATUS: draft v0.2. JARVIS began as one teacher's classroom system and is being turned into a version any teacher can set up. Everything described here is built, but it has not been fully tested yet.


WHAT IT DOES
------------

  - Assign work to one student, a group, or the whole class.
  - Boards and tables show who is working on what. Projects can contain
    smaller projects.
  - An Ask button lets students send you a question or request from anywhere
    in the app. You get notifications.
  - Reminders inside the app.
  - Calendar with day, week, and month views.
  - Lessons and polls you can run with the class.
  - Project bank of ideas students can pick up and requests you can approve.
  - Roster import from an Excel file, with printable password cards.
  - My list, a private to-do list just for you.
  - Backup and restore of your class data.
  - Accessibility tools: voice typing, read aloud, and a simplified view.

OPTIONAL MODULES (on/off switches in config.js): weekly reports
and check-ins, TV rundowns, Schoology sync log, A/B day schedule, weekly
Inspiration post, and a start-of-class slide. Turn on only what fits your
class.

JARVIS tracks work. It does not replace your gradebook or your school's
learning management system.


WHAT YOU NEED
-------------

  - A computer and about 30 to 45 minutes the first time
  - A free GitHub account (hosts the website): github.com
  - A free Supabase account (the database and sign-in): supabase.com
  - Optional: your class list as an Excel file

You do not need to know how to code. You will copy and paste a few things.


SET-UP
------
  1. GET THE FILES. On the project page choose Code, then Download ZIP, and
     unzip it.

1A. DURING SETUP, DO NOT USE THE TEMPORARY.TXT FILES! DELETE THOSE NOW! PLEASE CHECK ALL FOLDERS FOR TEMPORARY.TXT FILES.

  2. CREATE A SUPABASE PROJECT. Click New project, give it a name, save the
     database password somewhere safe, and pick a region close to you. Then
     go to Authentication > Sign In / Providers > Email and turn "Confirm
     email" OFF. (Students sign in with made-up addresses like
     maria@jarvis.local, so no real email is needed.)

  3. BUILD THE DATABASE. Open SQL Editor, paste in the whole contents of
     supabase/1-setup.sql, and click Run.

  4. CREATE YOUR TEACHER LOGIN. Go to Authentication > Users > Add user. Use
     yourname@jarvis.local, choose a password, and tick "Auto Confirm User".
     Your username is the part before the @.

  5. MAKE THAT LOGIN A TEACHER. Open supabase/2-make-me-teacher.sql, put
     your username and display name in, paste it into the SQL Editor, and
     click Run.

  6. ADD THE ACCOUNT HELPER. Go to Edge Functions > Deploy a new function >
     Via Editor. Name it exactly jarvis-admin, paste in supabase/jarvis-
     admin.ts, and click Deploy. This lets JARVIS create student accounts
     and set passwords for you.

  7. CONNECT THE WEBSITE TO YOUR DATABASE. In Supabase open Project Settings
     > API. Copy the Project URL and the "anon public" key into
     site/config.js. Change teacherPin to your own number.

  8. PUBLISH THE WEBSITE. On GitHub create a new repository and upload
     everything inside the site folder. Open Settings > Pages, choose
     "Deploy from a branch", pick main and / (root), and save. After a
     minute GitHub shows your link.

  9. SIGN IN with your teacher username and password.

IMPORTANT: Only ever use the "anon public" key. Never paste the
"service_role" key into config.js. It is a secret.


YOUR FIRST DAY
--------------

  1. Open Roster > Import and choose your Excel class list. A sample file is
     included at sample/fake-roster.xlsx.

  2. Print the password cards and hand them out.

  3. Create your first assignment and give it to the class.

  4. Have students sign in, find their work, and try the Ask button.


MAKE IT YOURS
-------------

site/config.js lets you set, without touching any code:

  - your name or title, your class name, and your school
  - your colors
  - which grade levels your class uses, from kindergarten through
    college (leave the list empty to offer all of them, or list only
    yours, for example ['7','8'])
  - which optional modules are on

PRIVACY AND SAFETY
------------------

  - Students sign in with a username and password you give them. No personal
    email address is required.
  - Your data lives in your own Supabase project, not on a server run by
    someone else. Backup and restore are built in.
  - Before you put real student names into any online tool, check your
    school or district's rules and ask your technology office. This README
    is not legal advice.
  - JARVIS never sends email and never asks for student email
    addresses.


COSTS AND LIMITS
----------------

JARVIS can run on the free plans of GitHub and Supabase. Free plan rules
change, and Supabase may pause projects that go unused for a while, which
matters over summer break. Check https://supabase.com/pricing for the
current rules and use Backup before long breaks.


TROUBLESHOOTING
---------------

  - Students cannot sign in: make sure "Confirm email" is OFF (step 2).
  - Blank page or "cannot connect": check the Project URL and anon key in
    config.js for typos or extra spaces.
  - My changes are not showing: GitHub Pages can take a minute or two.
    Refresh with Ctrl+Shift+R (Cmd+Shift+R on Mac).
  - "No permission" messages as a teacher: run 2-make-me-teacher.sql again
    with the right username.

Still stuck? Open an issue at [your-repo-link].


CREDITS
-------

  - JARVIS was created by Christian Pavlovich.
  - Shared edition developed by Robert Bottomley, in partnership with
    Christian Pavlovich.


LICENSE
-------

JARVIS is shared under the Creative Commons Attribution-NonCommercial 4.0
International license (CC BY-NC 4.0):
https://creativecommons.org/licenses/by-nc/4.0/

In plain terms: teachers and schools may use it, copy it, and adapt it for
free, as long as they give credit and do not sell it or use it for
commercial purposes. This summary is not the license. See LICENSE.md for the
full terms. Libraries bundled with JARVIS keep their own licenses.



~~~ NOTES FOR THE AUTHORS (delete before publishing) ~~~
Replace [your-repo-link]. Confirm the exact Creative Commons variant (this
draft assumes CC BY-NC 4.0) and add the full text as LICENSE.md. Final file
names in the supabase folder may differ from those used above.
