#!/usr/bin/perl
use strict;
use warnings;

use Getopt::Long;
use File::Basename;
use File::Glob ':glob';
use String::Escape qw(unbackslash);
use Config::Tiny;
use JSON;

# Subroutine to print usage instructions and exit
sub print_usage_and_exit {
    my $usage = <<"END_USAGE";
Usage: $0 [options]

Options:
    --input <PATTERN>     Specifies the input SuperSlicer INI file(s). (Required)
                          You can use wildcards to specify multiple files.
    --outdir <DIRECTORY>  Specifies the output directory where the JSON files will be saved. (Required)
    --overwrite           Allows overwriting existing output files. If not specified, the script will
                          exit with a warning if the output file already exists.
    -h, --help            Displays this usage information.

END_USAGE

    print $usage;
    exit(1);
}

# Initialize variables to store command-line options
my @input_files;
my $output_directory;
my $overwrite;

# Parse command-line options
GetOptions(
    "input=s@"  => \@input_files,
    "outdir=s"  => \$output_directory,
    "overwrite" => \$overwrite,
    "h|help"    => sub { print_usage_and_exit(); },
) or die("Error in command-line arguments.\n");

# Check if required options are provided
if ( !@input_files || !$output_directory ) {
    print_usage_and_exit();
}

# Define parameter mappings for translating the SuperSlicer INI settings
# to Orca Slicer JSON keys
my %parameter_map = (
    bed_temperature => [
        'hot_plate_temp', 'cool_plate_temp',
        'eng_plate_temp', 'textured_plate_temp'
    ],
    bridge_fan_speed               => 'overhang_fan_speed',
    chamber_temperature            => 'chamber_temperature',
    disable_fan_first_layers       => 'close_fan_the_first_x_layers',
    end_filament_gcode             => 'filament_end_gcode',
    external_perimeter_fan_speed   => 'overhang_fan_threshold',
    extrusion_multiplier           => 'filament_flow_ratio',
    fan_always_on                  => 'reduce_fan_stop_start_freq',
    fan_below_layer_time           => 'fan_cooling_layer_time',
    filament_colour                => 'default_filament_colour',
    filament_cost                  => 'filament_cost',
    filament_density               => 'filament_density',
    filament_deretract_speed       => 'filament_deretraction_speed',
    filament_diameter              => 'filament_diameter',
    filament_max_volumetric_speed  => 'filament_max_volumetric_speed',
    filament_retract_before_travel => 'filament_retraction_minimum_travel',
    filament_retract_before_wipe   => 'filament_retract_before_wipe',
    filament_retract_layer_change  => 'filament_retract_when_changing_layer',
    filament_retract_length        => 'filament_retraction_length',
    filament_retract_lift          => 'filament_z_hop',
    filament_retract_lift_above    => 'filament_retract_lift_above',
    filament_retract_lift_below    => 'filament_retract_lift_below',
    filament_retract_restart_extra => 'filament_retract_restart_extra',
    filament_retract_speed         => 'filament_retraction_speed',
    filament_shrink                => 'filament_shrink',
    filament_soluble               => 'filament_soluble',
    filament_type                  => 'filament_type',
    filament_wipe                  => 'filament_wipe',
    first_layer_bed_temperature    => [
        'hot_plate_temp_initial_layer', 'cool_plate_temp_initial_layer',
        'eng_plate_temp_initial_layer', 'textured_plate_temp_initial_layer'
    ],
    first_layer_temperature              => 'nozzle_temperature_initial_layer',
    full_fan_speed_layer                 => 'full_fan_speed_layer',
    inherits                             => 'inherits',
    max_fan_speed                        => 'fan_max_speed',
    min_fan_speed                        => 'fan_min_speed',
    min_print_speed                      => 'slow_down_min_speed',
    slowdown_below_layer_time            => 'slow_down_layer_time',
    start_filament_gcode                 => 'filament_start_gcode',
    support_material_interface_fan_speed =>
      'support_material_interface_fan_speed',
    temperature                          => 'nozzle_temperature',
    compatible_printers_condition        => 'compatible_printers_condition',
    compatible_printers                  => 'compatible_printers',
    compatible_prints_condition          => 'compatible_prints_condition',
    compatible_prints                    => 'compatible_prints',
    filament_vendor                      => 'filament_vendor',
    filament_minimal_purge_on_wipe_tower =>
      'filament_minimal_purge_on_wipe_tower'
);

# Mapping of SuperSlicer filament types to their Orca Slicer equivalents
my %filament_types = (
    PET   => 'PETG',
    FLEX  => 'TPU',
    NYLON => 'PA'
);

# Define default max volumetric speeds since this can't be zero in Orca Slicer
my %default_MVS = (
    PLA   => '15',
    PET   => '10',
    ABS   => '12',
    ASA   => '12',
    FLEX  => '3.2',
    NYLON => '12',
    PVA   => '12',
    PC    => '12',
    PSU   => '8',
    HIPS  => '8',
    EDGE  => '8',
    NGEN  => '8',
    PP    => '8',
    PEI   => '8',
    PEEK  => '8',
    PEKK  => '8',
    POM   => '8',
    PVDF  => '8',
    SCAFF => '8'
);

# Expand wildcards and process each input file
my @expanded_input_files;
foreach my $pattern (@input_files) {
    push @expanded_input_files, bsd_glob($pattern);
}

foreach my $input_file (@expanded_input_files) {

    # Extract filename, directory, and extension from the input file
    my ( $file, $dir, $ext ) = fileparse( $input_file, qr/\.[^.]*/ );

    # Initialize a hash to store translated JSON data
    my %new_hash = ();

    # Read the input INI file
    my $superslicer_ini = Config::Tiny->read( $input_file, 'utf8' )
      or die "Error reading $input_file: $!";
    my $max_temp = 0;    # Variable to keep track of maximum temperature

    # Loop through each parameter in the INI file
    foreach my $parameter ( keys %{ $superslicer_ini->{_} } ) {

        # Ignore SuperSlicer parameters that Orca Slicer doesn't support
        next unless exists $parameter_map{$parameter};

        # Get the value of the current parameter from the INI file
        my $new_value = $superslicer_ini->{_}->{$parameter};

        # If the SuperSlicer value is 'nil,' skip this parameter and let
        # Orca Slicer use its own default
        next if ( $new_value eq 'nil' );

        # Check if the parameter maps to multiple keys in the JSON data
        if ( ref( $parameter_map{$parameter} ) eq 'ARRAY' ) {

            # If yes, set the same value for each key in the JSON data
            $new_hash{$_} = $new_value for @{ $parameter_map{$parameter} };
            next;
        }

        # Handle special cases for specific parameter keys
        if ( $parameter =~ /^(start_filament_gcode|end_filament_gcode)/ ) {

            # The custom gcode blocks need to be unquoted and unbackslashed
            # before JSON encoding
            $new_value =~ s/^"(.*)"$/$1/;
            $new_value = [ unbackslash($new_value) ];
        }
        elsif ( $parameter eq 'filament_type' ) {

            # Translate filament type to a specific value if it exists in
            # the mapping, otherwise keep the original value
            $new_value = $filament_types{$new_value} // $new_value;
        }
        elsif ( $parameter eq 'filament_max_volumetric_speed' ) {

            # Max volumetric speed can't be zero so use a reasonable default
            # if necessary
            my $mvs =
              ( $new_value > 0 )
              ? $new_value
              : $default_MVS{ $superslicer_ini->{_}->{'filament_type'} };
            $new_value = "" . $mvs; # Must cast as a string before JSON encoding
        }
        elsif ( $parameter eq 'external_perimeter_fan_speed' ) {

            # 'external_perimeter_fan_speed' in SS is the closest equivalent to
            # 'overhang_fan_threshold' in Orca, so convert to percentage
            $new_value = ( $new_value < 0 ) ? '0%' : "$new_value%";
        }

        # Set the translated value in the JSON data
        $new_hash{ $parameter_map{$parameter} } = $new_value;

        # Track the maximum commanded nozzle temperature
        $max_temp = $new_value
          if $parameter =~ /^(first_layer_temperature|temperature)$/
          && $new_value > $max_temp;
    }

    # Add additional metadata to the JSON data
    $new_hash{'filament_settings_id'}         = $file;
    $new_hash{'name'}                         = $file;
    $new_hash{'from'}                         = 'User';
    $new_hash{'is_custom_defined'}            = '1';
    $new_hash{'nozzle_temperature_range_low'} = '0';
    $new_hash{'nozzle_temperature_range_high'} =
      "" . $max_temp;    # Must cast as a string before JSON encoding
    $new_hash{'slow_down_for_layer_cooling'} =
      $superslicer_ini->{_}{'slowdown_below_layer_time'} > 0 ? '1' : '0';
    $new_hash{'version'} = '1.6.0.0';

    # Construct the output filename
    my $output_file = $output_directory . $file . ".json";

    # Check if the output file already exists and handle overwrite option
    if ( -e $output_file && !$overwrite ) {
        die
"Output file '$output_file' already exists. Use --overwrite to force overwriting.\n";
    }

    # Write the JSON data to the output file
    open my $fh, '>', $output_file
      or die "Cannot open '$output_file' for writing: $!";
    my $json = JSON->new->pretty->encode( \%new_hash );
    print $fh $json;
    close $fh;

    print "Translated '$input_file' to '$output_file'.\n";
}
