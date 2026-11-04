# unraid-templates

Container templates for Unraid.

One XML file in `templates/` adds one container to the Unraid Docker tab. The
file gives the image reference, the ports, the paths, the variables, and the
artwork that Unraid shows. See [Install a template](#install-a-template).

## Layout

```
templates/    one XML file for each container (my-<name>.xml)
```

Icons and screenshots live in the image's own repository. Each XML points at
them with a raw URL.

## Templates

| Template                   | Image                   | Notes                                                                                  |
| -------------------------- | ----------------------- | -------------------------------------------------------------------------------------- |
| `templates/my-opengym.xml` | `0x1917/opengym:latest` | Workout and body-weight tracker ([OpenGym](https://github.com/DuarteSantos8/openGym)). | 

### Install a template

If the template is already on the Unraid Community Applications catalog, then just search
for the template and install it through the CA plugin. Otherwise, it can be manually installed:

1. On Unraid, copy the XML file into `/boot/config/plugins/dockerMan/templates-user/`
2. Open the Docker tab
3. Click **Add Container** 
4. Select the template from the drop-down menu
5. Fill in any required arguments
6. Click **Apply**
