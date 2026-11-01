# unraid-apps

Custom Docker images, container templates, and plugins for Unraid.

## Layout

```
images/<name>/     full build context per image (Dockerfile + context files)
templates/         Unraid dockerMan XML templates
plugins/           Unraid plugin sources
```

- **Build** runs on any Docker host:
  `tar -C images/<name> -cf - . | ssh root@<docker-host> 'mkdir -p /tmp/<name> && tar -C /tmp/<name> -xf - && docker build -t <tag> /tmp/<name>'`
- **Publish** pushes two tags — the version and `latest`:
  `docker tag <name>:<ver> 0x1917/<name>:<ver> && docker tag <name>:<ver> 0x1917/<name>:latest && docker push 0x1917/<name> --all-tags`
- **Deploy a template**: back up the flash copy, copy the XML over
  `/boot/config/plugins/dockerMan/templates-user/<file>`, then Docker tab →
  Edit → **Apply** (the Apply is the recreate).
- Image names pin every component version.

## Inventory

| Path             | Image                   | Template                   | Notes                                                                                                                                                                                                                                                           |
| ---------------- | ----------------------- | -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `images/opengym` | `0x1917/opengym:latest` | `templates/my-opengym.xml` | Single-container build of [openGym](https://github.com/DuarteSantos8/openGym) — Node API, nginx-served SPA and exercise media in one image, s6-overlay supervised, both services unprivileged. Details: [`images/opengym/README.md`](images/opengym/README.md). |
                                                                   
