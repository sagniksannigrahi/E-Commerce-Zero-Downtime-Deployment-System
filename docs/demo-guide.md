# ShopFlow — Live Demo Guide (5–7 minutes)

## Before the demo (do this 10 minutes early)

1. **Network:** some college Wi-Fi networks block SSH (port 22). Use a phone hotspot if `ssh` times out. The website on port 80 works on any network.
2. **Check the instance is running** in the AWS console. If it was stopped and started, its public IP changed: update the `EC2_HOST` secret and `ansible/inventory.ini`.
3. Open these tabs:
   * http://3.80.226.178 (the shop)
   * http://3.80.226.178/health
   * GitHub repo → **Actions** tab
4. Open two terminals in the project folder:
   * **Terminal A:** `deployment/traffic-monitor.sh` (leave it running)
   * **Terminal B:** for commands
5. Check which colour is live now. That tells you which colour the next deploy will switch to.

---

## Script

### 0:00 – 1:00 · The problem and the architecture
> "An e-commerce company has three problems: deployments often fail, servers are set up by hand, and releases cause downtime. I solved each one with a DevOps tool: **GitHub Actions** for failed deployments, **Ansible** for manual setup, and **Blue-Green deployment with Docker and Nginx** for downtime."

Show the architecture diagram in the README. Point out that Nginx sends traffic to **one** of two containers, blue or green.

### 1:00 – 1:45 · The application
* Open the shop. Add two products to the cart and open the cart drawer.
* Point at the **coloured ribbon** at the top ("Served by BLUE environment, v1.0.0").
* Point at the **Deployment monitor**: "This page checks the server every 2 seconds. Every coloured tick is a successful response; a failure would show in red."
* Open `/health`: "This is what the deployment script and the pipeline check."

### 1:45 – 2:30 · Ansible (manual server setup → automated)
Show `ansible/playbook.yml` briefly, then run:
```bash
cd ansible && ansible-playbook playbook.yml
```
> "This one command installed Docker, Docker Compose and Nginx, created swap, folders and permissions. Because it's **idempotent**, running it again on a configured server changes nothing — look, `changed=0`."

*(Over a slow network this can take a minute or two. You can show a screenshot of a previous `changed=0` run instead.)*

### 2:30 – 4:30 · Zero-downtime release (the main event)
Make sure **Terminal A** (traffic monitor) is visible next to the browser.

Option 1 — through CI/CD (best if the network is good):
```bash
echo "1.1.0" > VERSION
git commit -am "Release 1.1.0" && git push
```
Switch to the GitHub **Actions** tab: *Test → Build → Deploy*.

Option 2 — faster, from the laptop:
```bash
echo "1.1.0" > VERSION
deployment/push-release.sh
```

Narrate the deploy output:
> "Blue is live and keeps serving users. The script builds the new version and starts it in **green**. It health-checks green directly. Only when green is healthy does it switch Nginx with an **atomic file rename and a graceful reload**. Then it verifies through Nginx."

Option 3 — no SSH needed (campus Wi-Fi): GitHub → Actions → **Operations** → Run workflow → `zero-downtime-test`. The log ends with "Zero-downtime check: N requests, 0 failed".

Then show:
* Terminal A: the colour changes from `blue` to `green` with **fail=0**.
* Browser: the ribbon turns green, version 1.1.0 appears, and the switch history logs the change. **The cart still has its items.**

### 4:30 – 5:30 · A broken release is refused
```bash
deployment/push-release.sh --simulate-failure
```
> "This release is broken on purpose: its health check returns 503. Watch: the script health-checks it, sees it failing, stops it, and **never switches traffic**. Users stay on the working version."

Point at `Deployment ABORTED. Traffic was NOT switched` and at Terminal A (still fail=0).

### 5:30 – 6:15 · Instant rollback
```bash
ssh -i ~/Downloads/CloudDeploy-Deploy-Key.pem ubuntu@3.80.226.178
R=$(ls -1dt /opt/shopflow/releases/*/ | head -1)
bash $R/deployment/rollback.sh
bash $R/deployment/status.sh
```
> "The previous version was kept running as a hot standby, so rollback just switches Nginx back. It takes about two seconds and needs no rebuild."

### 6:15 – 7:00 · Tests and honest limitations
* Show the latest Actions run: 33 tests pass before anything is deployed. "If a single test fails, the deploy job never starts."
* Limitation: "This is **one** EC2 instance, so releases have no downtime, but if the machine itself fails the site goes down. Real high availability needs several instances in different availability zones behind a load balancer."

---

## If something goes wrong during the demo

| Symptom | Fix |
|---|---|
| `ssh: connect ... port 22: Operation timed out` | The network blocks SSH. Switch to a phone hotspot. |
| Site does not load at all | Instance stopped or IP changed. Check the EC2 console. |
| `Another deployment is already running` | That's the lock working. Wait for the other deploy to finish. |
| GitHub deploy job fails at SSH | Check the `EC2_*` secrets and that the security group allows port 22 from 0.0.0.0/0. |

---

## Viva questions and answers

**1. What is Blue-Green deployment?**
Two identical environments. One (blue) serves users while the new version is deployed to the other (green). After green passes its health checks, traffic is switched to it. The old one stays available for instant rollback.

**2. How is it zero-downtime if you reload Nginx?**
`nginx -s reload` (or `systemctl reload`) is **graceful**. The master process starts new workers with the new config, and old workers stop accepting new connections but finish the requests they are already handling before exiting. No request is cut off. The traffic monitor shows 0 failed requests during a switch.

**3. Why make the upstream switch "atomic"?**
The script writes the new config to a temporary file and then `mv`s it over the real one. A rename on the same filesystem is atomic, so Nginx never sees a half-written file. `nginx -t` validates it before reload, and if validation fails the old file is restored.

**4. What happens if the new version is broken?**
Its health check fails, so the script stops the new container and exits with an error **without switching traffic**. If a problem only appears after the switch (checks through Nginx fail), the script restores the previous Nginx config automatically.

**5. Why health-check both directly and through Nginx?**
The direct check proves the new container works before any user sees it. The check through Nginx proves the switch really happened and real traffic reaches the new version.

**6. How do you stop two deployments from running at once?**
Two layers: GitHub Actions `concurrency` stops overlapping workflow runs, and `deploy.sh` takes a lock with `mkdir`. Creating a directory is atomic, so only one process can succeed. A lock left by a crashed deployment is detected (its PID is no longer running) and removed.

**7. What does "idempotent" mean in Ansible?**
Running the playbook many times gives the same result as running it once. Modules describe a desired state ("nginx is installed") and only act when the server differs from it. A second run reports `changed=0`.

**8. Why Ansible and not a shell script?**
Ansible is declarative, idempotent and readable, reports exactly what changed, and the same playbook works on 1 or 100 servers. A shell script repeats every step every time and is harder to make safe to re-run.

**9. Why Docker?**
The app and all its dependencies are packaged into one image that runs the same on a laptop, in CI and on EC2. Blue and green are just two containers from the same image on different ports.

**10. What does the CI pipeline guarantee?**
`deploy` depends on `build`, which depends on `test`. If any test fails, or the image does not start and pass `/health`, nothing is deployed. Pull requests are tested but never deployed.

**11. How are secrets handled?**
The SSH key and host key are GitHub encrypted secrets, written to the runner only for the job and deleted afterwards. Nothing secret is in the repository (`.gitignore` blocks `*.pem` and `.env`). The Flask `SECRET_KEY` is generated on the server and stored in a file readable only by its owner.

**12. Why `EC2_KNOWN_HOSTS`?**
It holds the server's verified host key, so GitHub Actions connects with `StrictHostKeyChecking=yes`. This stops a man-in-the-middle from posing as the server and receiving our code and commands.

**13. Why does the cart survive a deployment?**
The cart is stored in a signed session cookie, and blue and green share the same `SECRET_KEY`, so the new version can read cookies created by the old one.

**14. What are the limitations?**
A single EC2 instance is a single point of failure, so there is no high availability. Other limitations: plain HTTP, images built on the server, and no database (schema migrations would need extra care in blue-green).

**15. How would you make this production-grade?**
Several instances across availability zones behind an AWS Application Load Balancer with Auto Scaling, images pushed to ECR, HTTPS, centralised logs and monitoring (CloudWatch/Prometheus), and infrastructure as code for the AWS resources.

**16. What is the difference between Blue-Green and rolling or canary deployments?**
Rolling replaces servers a few at a time. Canary sends a small percentage of traffic to the new version first. Blue-Green switches 100% of traffic at once but keeps the old version ready, which makes it the simplest to roll back.

**17. Why are the containers bound to 127.0.0.1?**
Only Nginx should reach them. Users cannot bypass the proxy and hit the inactive colour directly.

**18. What restarts the app if it crashes?**
Docker's `restart: unless-stopped` policy. The image's `HEALTHCHECK` also marks unhealthy containers in `docker ps`.
