# Deploying the Dark Factory Presentation on GitLab Pages

## Prerequisites
- A GitLab account with access to create projects
- Git installed locally

## Step 1: Create a GitLab Project
1. Go to GitLab and click **New Project** → **Create blank project**
2. Name it (e.g. `dark-factory`)
3. Set visibility to **Internal** or **Private**
4. Uncheck "Initialize repository with a README"
5. Click **Create project**

## Step 2: Push This Repo
```bash
cd /mnt/c/Users/drom/IdeaProjects/dark-factory
git init
git add presentation.html .gitlab-ci.yml
git commit -m "Dark Factory presentation with GitLab Pages deploy"
git remote add origin https://gitlab.com/<your-group>/<project-name>.git
git push -u origin main
```

## Step 3: Wait for the Pipeline
1. Go to **Build → Pipelines** in your GitLab project
2. A `pages` job will run automatically — it copies `presentation.html` into the `public/` folder as `index.html`
3. This takes about 1–2 minutes on first run

## Step 4: Enable and Configure Pages
1. Go to **Deploy → Pages** in your GitLab project
2. Your site URL will be shown, typically: `https://<your-group>.gitlab.io/<project-name>/`
3. If the project is private and you want anyone with the link to view it:
   - Go to **Settings → General → Visibility, project features, permissions**
   - Set **Pages** access to "Everyone" (public URL) or "Everyone with access" (requires GitLab login)

## Step 5: Share via Email
Copy the Pages URL and paste it into your email. Recipients tap the link on Outlook mobile (or any device) and the full animated presentation opens in their browser.

## Updating the Presentation
Any push to `main` automatically redeploys within ~2 minutes:
```bash
git add presentation.html
git commit -m "Update presentation"
git push
```

## Troubleshooting
- **Pages not showing:** Check Build → Pipelines — the `pages` job must pass with a green checkmark
- **404 after deploy:** Allow up to 10 minutes for the first deployment to propagate
- **Access denied:** Verify the Pages visibility setting in Step 4
- **Custom domain:** Go to Deploy → Pages → New Domain if you want a branded URL
