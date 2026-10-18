# Shared Agent Skills

Place portable Agent Skills here, one directory per skill with a `SKILL.md` file.
At runtime this directory is copied once to `/workspace/agent-lab/shared-skills`.
That persistent directory is exposed to both harnesses:

- Hermes Agent: `/opt/hermes-home/skills`
- Oh My Pi / Agent Skills: `/root/.agents/skills`

Edit the persistent `/workspace/agent-lab/shared-skills` copy on a pod after first boot.
