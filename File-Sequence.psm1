<#
	File-Sequence Powershell Module
	Created by Matt Tillman 2024 for the purpose of wrangling image sequences and to learn powershell scripting.

	Frame number rules:
		- Must be the last thing before the file extension
		- Must be preceeded by either an underscore or dot separator
		- No negative or fractional numbers

	These rules were chosen because they suit my specific purposes and simplify the path matching.
#>

$SEQ_PATTERN = '' +
	'\A' +                        # start of line
	'(?<dirname>(?:.*[/\\])?)' +  # dirname
	'(?<basename>(?:.*[_\.])?)' + # basename
	'(?<frame>\d+)?' +            # frame
	'(?<extension>' +
	'(?:\.\w*[a-zA-Z]\w?)*' +     # optional leading alnum ext prefix (.foo.1bar)
	'(?:\.[^.]+)?' +              # ext suffix
	')' +
	'\Z'                          # end of line

$SEQ_REGEX = [regex]::new($SEQ_PATTERN, "Compiled")


function Concat-Frames  {
	<#
		.SYNOPSIS
			Takes an array of frame numbers and returns a shortened string representation.
			For example: 1 ... 10 -> 1-10

			Broken ranges are separated by commas. e.g. 1-7,9-10.
	#>

	[OutputType([String])]
	param (
		[Parameter(Mandatory = $true, Position = 0)]
		[int[]]
		$frames 
	)

	$result = ""
	$lastValue = -1
	$continuing = $false
	foreach ( $frame in $frames ) {
		if ( $lastValue -eq -1 ) {
			# First frame
			$result = "$frame"
		} elseif ( $frame -eq $lastValue + 1 ) {
			# Continuing Sequence
			$continuing = $true
		} else {
			# Broken Range
			if ( $continuing ) {
				$result = "$result-$lastValue,$frame"
			} else {
				$result = "$result,$frame"
			}

			$continuing = $false
		}

		$lastValue = $frame
	}

	# Append last frame if last range is unbroken
	if ( $continuing ) {
		$result = "$result-$lastValue"
	}

	$result
}


function Format-SequencePath {
	<#
		.SYNOPSIS
			Takes a path string with a frame number or frame placeholder and returns that string with a frame
			placeholder of the desired format.
			The default output placeholder format is printf style, i.e. '%04d'.

			Detects printf style placeholders or a sequence of digits or '#'s, provided that the frame number or
			placeholder is preceeded by a dot or underscore and followed by a dot.
			i.e. '.\test.1234.exr' or '.\test_1234.exr'

			If no frame or placeholder is found the original path is returned.

		.EXAMPLE
			Format-SequencePath .\test.1234.exr % -> .\test.%04d.exr
		.EXAMPLE
			Format-SequencePath .\test.%05d.exr # -> .\test.#####.exr
	#>

	[OutputType([String])]
	param (
		# Path string with frame number or frame placeholder
		# Frame number/placeholder must be a sequence of digits or '#'s or printf style '%04d'
		[Parameter(Mandatory = $true, Position = 0)]
		[String]
		$path,

		# Specify a character to use as a frame placeholder.
		# This character will be repeated to match the padding of the input.
		# Defaults to '%' which will return a printf style placeholder, i.e. '%04d'.
		# An empty string will omit the frame and preceeding separator from the output.
		[Parameter(Position = 1)]
		[String]
		$pad = '%',
		
		# Add suffix before frame separator.
		[String]
		$suffix = '',
		
		# Add prefix to start of filename
		[String]
		$prefix = '',
		
		# Change extension
		[String]
		$extension,

		# New directory
		[String]
		$directory
	)

	$input_directory = Split-Path $path
	$name = Split-Path $path -Leaf
	$basename = Split-Path $path -LeafBase

	if ($PSBoundParameters.ContainsKey('directory') -eq $false) {
		$directory = $input_directory
	}

	if ($PSBoundParameters.ContainsKey('extension') -eq $false) {
		$extension = Split-Path $path -Extension
	} elseif (!$extension.StartsWith('.')) {
		$extension = ".$extension"
	}

	if( $name -match '([_\.])([\d#]+)\.' ) {
		# Matches 1234, #### style frames
		$pad_amount = $matches[2].length
	} elseif ($name -match '([_\.])(\%\d{1,2}d)\.') {
		# Matches %04d style frames
		$pad_amount = [int]$matches[2].Substring(1,2)
	} else {
		# No frame found
		return $path
	}
	
	$placeholder = ''
	if ( $pad -eq '%' ) {
		$placeholder = "$($matches[1])%0$($pad_amount)d"
	} elseif ($pad -ne '') {
		$placeholder +=  "$($matches[1])$("$pad" * $pad_amount)"
	}

	$result = "$directory\$prefix$basename$extension".Replace($matches[0], "$suffix$placeholder.")
	$result
}


function FrameInfo-From-ConcatFrames {
	<#
		.SYNOPSIS
			Convert a concatenated list of frames to an object with frame information.
	#>
	[OutputType([Object])]
	Param(
		[String]
		$Frames
	)
	Process {
		$split = $Frames -split {$_ -eq '-' -or $_ -eq ','}
		if ($split.Length -eq $Frames.Length) {
			$first = [int]$Frames
			$last = [int]$Frames
			$count = 1
		}else{
			$first = [int]$split[0]
			$last = [int]$split[-1]
			# TODO: count frames properly
			$count = $last - $first + 1
		}

		[pscustomobject]@{First=$first; Last=$last; Count=$count}
	}

}


function Get-Sequence {
	<#
		.SYNOPSIS
			Wrapper around Get-ChildItem that finds file sequences from a given path.
			Can also accept a file path or file path pattern to find specific sequence or sequences.
		.OUTPUTS
			Returns a pscustomobject consisting of the following properties:
				string Path - A relative filepath of the file sequence with %04d style frame placeholder
				string Frames - A concatenated list of frame numbers, ranges denoted by dashes and multiple
					ranges separated by commas. i.e. 1-10,15-20
				int First - The first frame number
				int Last - The last frame number
				int Count - The total number of frames
	#>

	[OutputType([Object[]])]
	param (
		# Root directory to begin search from. Defaults to current directory.
		# Alternatively a file path/pattern. i.e. .\example.1001.exr, .\example.*.exr, example.%04d.exr
		[Parameter(Position = 0)]
		[string]
		$path = ".\",
		
		# Optional file inclusion pattern. e.g. *.jpg
		[string[]]
		$include,
		
		# Optional file exclusion pattern. e.g. *.png
		[string[]]
		$exclude,

		# Search for sequences recursively
		[switch]
		$recurse
	)

	# Replace frame numbers or frame representations (%04d, #####) with ? wildcard
	# Allows for $path to be a specific sequence as long as frames all have the same padding.
	$PSBoundParameters['path'] = (Format-SequencePath $path '?')

	$sequences = @{}
	foreach ( $file in Get-ChildItem @PSBoundParameters | where { ! $_.PSIsContainer } | Sort-Object ) {
		$match = $SEQ_REGEX.Matches($file)
		if(! $match.Success ){ continue }

		$placeholder = "%0{0}d" -f $match[0].Groups['frame'].Length
		$sequence_path = "$($match[0].Groups['dirname'])$($match[0].Groups['basename'])$placeholder$($match[0].Groups['extension'])"
		
		if ( $sequences.ContainsKey($sequence_path) ) {
			$sequences[$sequence_path] += "$($match[0].Groups['frame'])"
		} else {
			$sequences[$sequence_path] = @("$($match[0].Groups['frame'])")
		}
	}

	$result = @()

	foreach ($h in ($sequences.GetEnumerator() | sort -Property name)){
		$relative_path = $h.Name.Replace("$(Get-Location)", '.')
		$concat_frames = Concat-Frames($h.Value)
		$result += , [pscustomobject]@{
			Path="$relative_path";
			Frames=$concat_frames;
			First=[int]$h.Value[0];
			Last=[int]$h.Value[-1];
			Count=$h.Value.Length }
	}

	$result
}


function Add-Sequence-Output {
	<#
		.SYNOPSIS
			A wrapper around Format-SequencePath to add an output path property to a sequence object.
			Used to prepare a file sequence object for conversion, encoding or any other operation requiring an
			output path.
		.OUTPUTS
			A file sequence object with added "Output" string property.
	#>

	[OutputType([Object])]
	Param (
		[Parameter(Mandatory=$true, ValueFromPipeline=$true)]
		[Object]
		$Input,

		[String]
		$pad = '%',
		
		[String]
		$suffix = '',
		
		[String]
		$prefix = '',
		
		[String]
		$extension,

		[String]
		$directory
	)

	Process {
		$params = @{}
		foreach ($param in $PSBoundParameters.GetEnumerator()) {
			if ($param.key -eq 'Input' ) {
				continue
			}

			$params.add($param.key, $param.value)
		}

		$output_path = Format-SequencePath $Input.Path @params		
		$Input | Add-Member -NotePropertyName Output -NotePropertyValue $output_path
		$Input
	}
}

function Convert-Sequence {
	<#
		.SYNOPSIS
			A wrapper to pass sequence objects to (h)oiiotool for image conversion.
		.OUTPUTS
			A new file sequence object representing the converted image sequence.
	#>

	[CmdletBinding()]
	[OutputType([Object])]
	Param(
		[Parameter(Mandatory=$true, Position=0, ValueFromPipelineByPropertyName=$true)]
		[String]
		$Path,
		
		[Parameter(Mandatory=$true, Position=1, ValueFromPipelineByPropertyName=$true)]
		[String]
		$Frames,
		
		[Parameter(Mandatory=$true, Position=2, ValueFromPipelineByPropertyName=$true)]
		[String]
		$Output,
		
		# oiiotool arguments as a string. i.e. '--iscolorspace "scene_linear" --ociodisplay "sRGB - Display" "ACES 1.0 - SDR Video"'
		[Parameter(Position=3)]
		[string]
		$oiio_args
	)

	Process {
		$process = Start-Process hoiiotool -ArgumentList "$Path",--frames,$Frames,$oiio_args,-v,-o,"$Output" -NoNewWindow -Wait

		#& hoiiotool "$Path" --frames $Frames -v -o "$Output" *>&1 | Out-Host

		$frame_info = FrameInfo-From-ConcatFrames $Frames
		[pscustomobject]@{Path=$Output; Frames=$Frames; First=$frame_info.First; Last=$frame_info.Last; Count=$frame_info.Count}
		
	}
}


function Encode-Sequence {
	<#
		.SYNOPSIS
			A wrapper to pass sequence objects to ffmpeg for video encoding.
		.OUTPUTS
			A file object representing the encoded video.
	#>

	[CmdletBinding()]
	[OutputType([Object])]
	Param(
		[Parameter(Mandatory=$true, Position=0, ValueFromPipelineByPropertyName=$true)]
		[String]
		$Path,

		[Parameter(Mandatory=$true, Position=1, ValueFromPipelineByPropertyName=$true)]
		[String]
		$First,
		
		[Parameter(Mandatory=$true, Position=2, ValueFromPipelineByPropertyName=$true)]
		[String]
		$Output,

		[string]
		$framerate,
		
		# ffmpeg arguments as a string
		[string]
		$ffmpeg_args
	)

	Process {
		# TODO: Implement range (i.e. First - Last) to allow for range editing
		Start-Process ffmpeg -ArgumentList '-y',-r,$framerate,-start_number,$First,-i,"`"$Path`"",$ffmpeg_args,"`"$Output`"" -NoNewWindow -Wait

		Get-Item "$Output"	
	}
}


# Preset Wrappers

function Sequence-To-sRGB {
	<#
		.SYNOPSIS
			Helper function to simplify the conversion of file linear ACES image sequences to sRGB.
			This is very project specific so will probably change a lot.
		.OUTPUTS
			File sequence object representing the new sRGB converted image sequence.
	#>
	[CmdletBinding()]
	[OutputType([Object])]
	param(
		[Parameter(Mandatory=$true, ValueFromPipeline=$true)]
		[object]
		$Input,

		[string]
		$Preset = 'exr',

		[switch]
		$parallel
	)
	Process{
		$oiio_args =  '-a --iscolorspace "scene_linear" --ociodisplay:subimages=-matte,-N,-depth "sRGB - Display" "ACES 1.0 - SDR Video"'
		#$oiio_args =  '-a --ociodisplay "sRGB - Display" "ACES 1.0 - SDR Video"'
		if ($Preset -eq 'exr'){
			$oiio_args += ' --compression dwab:85'
		}

		if($parallel) {
			$oiio_args += ' --parallel-frames'
		}

		$Input | Add-Sequence-Output -suffix '.sRGB' -extension $Preset | Convert-Sequence -oiio_args $oiio_args
	}
}


function Sequence-To-MP4 {
	<#
		.SYNOPSIS
			Helper function to simplify the encoding of an image sequence to h624, mp4 video.
		.OUTPUTS
			File object representing the encoded video.
	#>
	[CmdletBinding()]
	[OutputType([Object])]
	param(
		[Parameter(Mandatory=$true, ValueFromPipeline=$true)]
		[object]
		$Input,

		[string]
		$Framerate = '25'
	)
	Process {
		$Input | Add-Sequence-Output -pad '' -directory '.' -extension 'mp4' | Encode-Sequence -framerate $Framerate -ffmpeg_args '-pix_fmt yuv420p -vf "scale=width=ceil(iw/2)*2:height=ceil(ih/2)*2:in_color_matrix=bt709:out_color_matrix=bt709" -c:v libx264 -preset slower -crf 18 -color_range tv -colorspace bt709 -color_primaries bt709 -color_trc iec61966-2-1 -movflags faststart'
	}
}


function View-Sequence {
	<#
		.SYNOPSIS
			Opens file sequence in DJV.
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory=$true, ValueFromPipeline=$true)]
		[object]
		$Input
	)
	Process {
		# djv doesn't like %04d style naming
		$path = Format-SequencePath $Input.path -pad '#'

		# Need to override the OCIO variable as djv doesn't support v2 configs
		Start-Process djv -ArgumentList $path -UseNewEnvironment -NoNewWindow
	}
}
