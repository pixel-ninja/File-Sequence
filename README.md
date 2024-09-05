# File-Sequence
A Powershell module for handling file sequences.

Created primarily to tinker with learning windows shell scripting while also being useful for some basic CG/VFX tasks that I would normally handle with python tools.
In its current state it's mainly useful for frame checking, to make sure a sequence hasn't dropped any frames during render/upload/download/transfer/etc.

# Installation
Clone into your Powershell Modules folder.

Usually C:\Users\USERNAME\Powershell\Modules

# Usage
## Display
### Find File Sequences
```powershell
Get-Sequence -Recurse | Format-Table
```

### Using Filters
```powershell
Get-Sequence .\ -Recurse -Include *Final_Final*
```
```powershell
Get-Sequence .\ -Recurse -Exclude *v001*,*v007*,*proxy*
```

### Check Specific Sequence
```powershell
Get-Sequence ".\path\to\sequence.%04d.exr"
```

### Play Sequences
```powershell
# Open sequences in DJV
Get-Sequence | View-Sequence
```

## Conversion
```powershell
# Encode sequences with ffmpeg
Get-Sequence | Add-Sequence-Output -directory "." -pad "" -extension "mp4" | Encode-Sequence -framerate 25 -ffmpeg_args "-pix_fmt yuv420p -c:v libx264"
```

```powershell
# Convert sequences with (h)oiiotool
Get-Sequence | Add-Sequence-Output -suffix ".sRGB" | Convert-Sequence -oiio_args --ociodisplay "sRGB - Display" "ACES 1.0 - SDR Video"
``
