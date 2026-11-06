# Setup for running AI agents in a lima VM sandbox

## Goals and threat model

This setup tries to cover for 2 kinds of threats (either from a bad or compromised agent):

- doing destructing things with host resources: files, but also SSH into remotes using host's
  private key, connecting to remote resources using host's credentials (kubectl, gh, etc.).
- exfiltrating secrets (API keys, SSH private keys) to malicious remote locations.

A VM that does not mount any host's files cover for the first kind. Covering for the second requires
being able to filter traffic from the agent running in the guest VM to only a list of selected
locations (e.g. npm, crates.io). Most IDEs then support pointing to a remote environnement/folder
for transparent development from the host.

[Lima VM](https://lima-vm.io/docs/) provides a simple CLI to manage lightweight Linux VM. Especially
their [`--sync`](https://lima-vm.io/docs/examples/ai/#comparison-with-mount) option seems well
suited to exchange code between the host and the guest VM without mounting host location into the
guest.

Restricting the egress traffic of the guest VM is not within the scope of Lima VMs, so we need to
roll our own solution to filter guest requests.

## Setup firewall and proxy

First add a dedicated user to run the guest VM as it will be used to filter traffic.

```bash
sudo useradd -m -G kvm lima-agent
```

Then setup egress service and squid proxy.

```bash
sudo cp lima-egress.service /etc/systemd/system/lima-egress.service
sudo cp /etc/squid/squid.conf /etc/squid/squid.conf.backup
sudo cp squid.conf /etc/squid/squid.conf
sudo cp allow_domains.txt /etc/squid/allowed_domains.txt
sudo cp lima-egress.nft /etc/nftables/
sudo systemctl enable --now lima-egress squid
```

### Update allowed domains

To update the squid's list of allowed domains, first edit `allowed_domains.txt` here and copy it to
squid's location, then reload the service:

```bash
sudo cp allow_domains.txt /etc/squid/allowed_domains.txt
sudo squid -k parse
sudo systemctl reload squid
```

To check squid logs:

```bash
sudo tail -f /var/log/squid/access.log
```

## Build the base image

The guest VM requires installing external dependencies (rust toolchain, node, pi, etc.) to be
functional. To avoid having to add each dependency's domain to the list of squid's allowed domains
(and since these domains should not be needed by the agent), we first build a base image containing
all necessary dependencies. The builder is build using the regular user (not `lima-agent`) so that
it's not affected by the egress rules and can fetch all necessary dependencies (it's not the goal of
this setup to protect or audit this part of the supply chain). Once the base image is built it can
then be used as a base when creating new VMs using the dedicated `lima-agent` user, those VMs will
have their traffic filtered.

```bash
chomd +x build-image.sh
./build-image.sh
```

You can edit `lima-builder.yaml` to add new dependencies and then rebuild the base image. Guest VMs
will need to be recreated (stopped, deleted and created) to use the new base image.

## Create guest VMs

First copy the template for the guest VMs to the user `lima-agent` home directory (if you update
this file here donc forget to copy it back to the dedicated user's home).

```bash
sudo cp lima-agent.yaml /home/lima-agent/lima-agent.yaml
```

Now you can create and start dedicated guest VMs using out template and base image:

```bash
sudo -iu lima-agent /home/linuxbrew/.linuxbrew/bin/limactl create --name=agent ./lima-agent.yaml
sudo -iu lima-agent /home/linuxbrew/.linuxbrew/bin/limactl start agent
sudo -iu lima-agent /home/linuxbrew/.linuxbrew/bin/limactl shell agent
```

You can alias `lima-agent`'s `limactl` for ease of use, e.g. for fish and assuming `lima` has been
installed using homebrew: `alias lm="sudo -iu lima-agent /home/linuxbrew/.linuxbrew/bin/limactl"`.

You can check that dependencies and egress work properly:

```bash
sudo -iu lima-agent /home/linuxbrew/.linuxbrew/bin/limactl shell agent
rustc --version                 # should be installed
cargo search serde              # should be able to contact crates.io
curl -sI https://example.com    # should get a 403 from from squid
```

## Remote development with Zed and other IDEs

### SSH into the guest VM from your host user

The agent VMs are started by the dedicated `lima-agent` host user, so their SSH endpoint
(`127.0.0.1:60022`) authenticates against Lima's per-user key at
`/home/lima-agent/.lima/_config/user`. Since your own user cannot read it, Zed and other IDEs
running as your regular user need a readable copy of that key plus a `Host` block describing the
connection.

Copy Lima's key for the agent VMs so your user can read it:

```bash
sudo install -m 600 -o "$USER" -g "$USER" \
  /home/lima-agent/.lima/_config/user ~/.ssh/lima-agent
```

Describe the VM in your SSH config (~/.ssh/config already Includes ~/.lima/*/ssh.config)

```bash
# agent sandbox VM (managed by the lima-agent host user)
Host lima-agent
  HostName 127.0.0.1
  Port 60022
  User lima-agent
  IdentityFile ~/.ssh/lima-agent
  IdentitiesOnly yes
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
```

Check the connection:

```bash
ssh lima-agent
```

### Syncing a project directory without mounting file

To exchange files between the host and the guest we can use `rsync` over ssh (setup in the previous
section) to avoid having to mess with permission on the host side.

To send repository from the host to the guest:

```bash
rsync -av --exclude-from=".limasyncignore" -e ssh /home/user/project lima-agent:/home/lima-agent.guest/project
```

To get back diffs made on the guest to the host:

```bash
rsync -av --exclude-from=".limasyncignore" -e ssh lima-agent:/home/lima-agent.guest/project/ /home/user/project
```

Don't forget the trailing `/` on the guest path, else the directory content will not be copy at your
host project root but copied at `/home/user/project/project`.

Use the content of `.limasyncignore` to exclude files from the sync.

### Zed remote configuration

Then add the connection to `~/.config/zed/settings.json` as per
[their doc](https://zed.dev/docs/remote-development#configuration):

```json
{
  "ssh_connections": [
    {
      "host": "lima-agent",
      "username": "lima-agent",
      "projects": [{ "paths": ["/home/lima-agent.guest"] }]
    }
  ]
}
```

`username` must be set explicitly: otherwise Zed defaults to your local username and overrides the
`User` from the SSH config. `lima-agent` has its home set at `/home/lima-agent.guest` (note the
`.guest`).

### Which agent runs where (sandboxing)

Remote development does **not** mean every IDE's AI feature runs on the guest depending on how your
IDE is designed. Which process makes the model calls, and therefore whether it is subject to the
egress filter, depends on the agent you use. Here are the differences for Zed as of November 2026,
check for your specific IDE otherwise.

- **External / ACP agents** (anything under `agent_servers` in Zed's settings, e.g. `pi-acp`,
  `claude-acp`, `github-copilot-cli`): the agent **process runs on the guest**.
- **Zed's native "Zed Agent"**: the agent loop runs **on the host**. Its file edits and
  terminal/tool calls are routed to the guest over the RPC channel, but its **LLM API requests
  originate from the host** with host credentials and network policy. It is **not** covered by the
  `lima-agent` egress filter. Host-side model features such as the inline assistant and edit
  prediction behave the same way.

## Troubleshooting

- if a dependency is not present in a guest VM you can:
  - check that it is correctly installed in the `builder` image:
    `limactl shell builder -- rustc --version`.
  - check that the guest VM is using the `builder` image as a base:
    `sudo -iu lima-agent limactl list agent --format json | jq '.config.images'`. It should point to
    the output location of `build-image.sh` (`/srv/lima-images/`) and not to Fedora's download.
  - if you've edited the agent VM template `lima-agent.yaml`, check you've copied it to
    `lima-agent`'s home: `sudo cp lima-agent.yaml /home/lima-agent/lima-agent.yaml`.
- if you have trouble connecting via SSH into the guest VM make sure Lima has not regenerated the
  user config `/home/lima-agent/.lima/_config/user`, else redo
  [these steps](#ssh-into-the-guest-vm-from-your-host-user).
- if your application has tests that start a local HTTP server and send requests to it, your request
  library might honor the HTTP_PROXY environment variable: test requests will leave the sandbox, be
  blocked by squid and your tests will fail. Check squid logs
  (`sudo tail -f /var/log/squid/access.log`) to confirm that, then check your request library for
  how to run it without proxy (e.g. for `reqwest`: `reqwest::Client::builder().no_proxy().build()`).
- your development server (e.g. `vite dev`) running on the guest should be accessible from the host
  at e.g. `http://localhost:5173` (host -> guest connections are not filtered). See Lima's
  documentation on [port forwarding](https://lima-vm.io/docs/config/port/) for more control.
