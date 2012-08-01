package Slic3r::GCode;
use Moo;

use Slic3r::ExtrusionPath ':roles';
use Slic3r::Geometry qw(scale unscale);

has 'layer'              => (is => 'rw');
has 'shift_x'            => (is => 'rw', default => sub {0} );
has 'shift_y'            => (is => 'rw', default => sub {0} );
has 'z'                  => (is => 'rw', default => sub {0} );
has 'speed'              => (is => 'rw');

has 'extruder_idx'       => (is => 'rw', default => sub {0});
has 'extrusion_distance' => (is => 'rw', default => sub {0} );
has 'elapsed_time'       => (is => 'rw', default => sub {0} );  # seconds
has 'total_extrusion_length' => (is => 'rw', default => sub {0} );
has 'retracted'          => (is => 'rw', default => sub {1} );  # this spits out some plastic at start
has 'lifted'             => (is => 'rw', default => sub {0} );
has 'last_pos'           => (is => 'rw', default => sub { Slic3r::Point->new(0,0) } ); # end point of previous loop
has 'pen_pos'           => (is => 'rw', default => sub { Slic3r::Point->new(0,0) } ); # penultimate point of previous loop
has 'retract_pos'           => (is => 'rw', default => sub { Slic3r::Point->new(0,0) } ); # 
has 'old_start'           => (is => 'rw', default => sub { Slic3r::Point->new(0,0) } ); # 
has 'last_speed'         => (is => 'rw', default => sub {""});
has 'last_fan_speed'     => (is => 'rw', default => sub {0});
has 'dec'                => (is => 'ro', default => sub { 3 } );
has 'prev_role'          => (is => 'rw', default => sub {0});

# calculate speeds (mm/min)
has 'speeds' => (
    is      => 'ro',
    default => sub {{
        travel              => 60 * $Slic3r::Config->get_value('travel_speed'),
        perimeter           => 60 * $Slic3r::Config->get_value('perimeter_speed'),
        small_perimeter     => 60 * $Slic3r::Config->get_value('small_perimeter_speed'),
        external_perimeter  => 60 * $Slic3r::Config->get_value('external_perimeter_speed'),
        infill              => 60 * $Slic3r::Config->get_value('infill_speed'),
        solid_infill        => 60 * $Slic3r::Config->get_value('solid_infill_speed'),
        top_solid_infill    => 60 * $Slic3r::Config->get_value('top_solid_infill_speed'),
        bridge              => 60 * $Slic3r::Config->get_value('bridge_speed'),
        retract             => 60 * $Slic3r::Config->get_value('retract_speed'),
    }},
);

my %role_speeds = (
    &EXTR_ROLE_PERIMETER                    => 'perimeter',
    &EXTR_ROLE_SMALLPERIMETER               => 'small_perimeter',
    &EXTR_ROLE_EXTERNAL_PERIMETER           => 'external_perimeter',
    &EXTR_ROLE_CONTOUR_INTERNAL_PERIMETER   => 'perimeter',
    &EXTR_ROLE_FILL                         => 'infill',
    &EXTR_ROLE_SOLIDFILL                    => 'solid_infill',
    &EXTR_ROLE_TOPSOLIDFILL                 => 'top_solid_infill',
    &EXTR_ROLE_BRIDGE                       => 'bridge',
    &EXTR_ROLE_SKIRT                        => 'perimeter',
    &EXTR_ROLE_SUPPORTMATERIAL              => 'perimeter',
    &EXTR_ROLE_HOLE                         => 'perimeter',
);

use Slic3r::Geometry qw(points_coincide PI X Y);

sub extruder {
    my $self = shift;
    return $Slic3r::extruders->[$self->extruder_idx];
}

sub change_layer {
    my $self = shift;
    my ($layer) = @_;
    
    $self->layer($layer);
    my $z = $Slic3r::Config->z_offset + $layer->print_z * &Slic3r::SCALING_FACTOR;
    
    my $gcode = "";
    
    $gcode .= $self->retract(move_z => $z);
    $gcode .= $self->G0(undef, $z, 0, 'move to next layer (' . $layer->id . ')')
        if $self->z != $z && !$self->lifted;
    
    $gcode .= $Slic3r::Config->replace_options($Slic3r::Config->layer_gcode) . "\n"
        if $Slic3r::Config->layer_gcode;
    
    return $gcode;
}

sub extrude {
    my $self = shift;
    
    ($_[0]->isa('Slic3r::ExtrusionLoop') || $_[0]->isa('Slic3r::ExtrusionLoop::Packed'))
        ? $self->extrude_loop(@_)
        : $self->extrude_path(@_);
}

sub extrude_loop {
    my $self = shift;
    my ($loop, $description) = @_;
    
    # extrude all loops ccw
    $loop = $loop->unpack if $loop->isa('Slic3r::ExtrusionLoop::Packed');
    #print "loop role ";print $loop->role;print "\n";
    $loop->polygon->make_counter_clockwise if ($loop->role == 10);
    $loop->polygon->make_clockwise if ($loop->role == 2);
    
    # find the point of the loop that is closest to the current extruder position
    # or randomize if requested
    my $last_pos = $self->last_pos;
    if ($Slic3r::Config->randomize_start && $loop->role == EXTR_ROLE_CONTOUR_INTERNAL_PERIMETER) {
        srand $self->layer->id * 10;
        $last_pos = Slic3r::Point->new(scale $Slic3r::Config->print_center->[X], scale $Slic3r::Config->bed_size->[Y]);
        $last_pos->rotate(rand(2*PI), $Slic3r::Config->print_center);
    }
    my $start_index = $loop->nearest_point_index_to($last_pos);
    
    # split the loop at the starting point and make a path
    my $extrusion_path = $loop->split_at_index($start_index);
    
    # clip the path to avoid the extruder to get exactly on the first point of the loop;
    # if polyline was shorter than the clipping distance we'd get a null polyline, so
    # we discard it in that case
    $extrusion_path->clip_end(scale($self->layer ? $self->layer->flow->width : $Slic3r::flow->width) * 0.25); # was 0.15 jmg
    return '' if !@{$extrusion_path->polyline};
    
    # extrude along the path
    return $self->extrude_path($extrusion_path, $description);
}

sub extrude_path {
    my $self = shift;
    my ($path, $description, $recursive) = @_;

    $path = $path->unpack if $path->isa('Slic3r::ExtrusionPath::Packed');
    
    #if extrude_path is shorter than two extrusion widths, ignore it
    return '' if $path->polyline->length < scale ($self->layer ? $self->layer->flow->width : $Slic3r::flow->width) * 3;
    
   	$self->old_start($path->points->[0]) if ($path->role == 0 || $path->role == 3);
    if ($path->role == 0 || $path->role == 3 || $path->role == 10 || $path->role == 2) {
	    $path->clip_start(scale($self->layer ? $self->layer->flow->width : $Slic3r::flow->width) * 0.5);
	}
    $path->clip_end(scale($self->layer ? $self->layer->flow->width : $Slic3r::flow->width) * 0.5) if ($path->role == 0 || $path->role == 3);
    $path->merge_continuous_lines;
    
    # detect arcs
    if ($Slic3r::Config->gcode_arcs && !$recursive) {
        my $gcode = "";
        foreach my $arc_path ($path->detect_arcs) {
            $gcode .= $self->extrude_path($arc_path, $description, 1);
        }
        return $gcode;
    }
    
    my $gcode = "";
    
    # retract if distance from previous position is greater or equal to the one
    # specified by the user *and* to the maximum distance between infill lines
    {
        my $distance_from_last_pos = $self->last_pos->distance_to($path->points->[0]) * &Slic3r::SCALING_FACTOR;
        my $distance_threshold = $Slic3r::Config->retract_before_travel;
        $distance_threshold = 2 * ($self->layer ? $self->layer->flow->width : $Slic3r::flow->width) / $Slic3r::Config->fill_density * sqrt(2)
            if 0 && $Slic3r::Config->fill_density > 0 && $description =~ /fill/;
    
        if ($distance_from_last_pos >= $distance_threshold) {
        	#print "retract req. dist pen -> last";print $self->pen_pos->distance_to($self->last_pos) * $Slic3r::scaling_factor;print "\n";
        	if (defined $self->retract_pos && defined $self->prev_role && ($self->prev_role == 10 || $self->prev_role == 2)) {
	        	#jmg - retract to one extrusion width towards next thread
	        	#print "retract move ";print $path->role;print " \n";
	        	#print " from X";print unscale $self->last_pos->x;print " to Y";print unscale $self->last_pos->y;print "\n";
	        	#print " to X";print unscale $self->retract_pos->x;print " to Y";print unscale $self->retract_pos->y;print "\n";
	            $gcode .= $self->retract(retract_move_to => $self->retract_pos);
	        } else {
	        	#print "retract stat ";print $path->role if defined $path->role;print "\n";
            	$gcode .= $self->retract(travel_to => $path->points->[0]);
           	}
        }
    }
    
    # go to first point of extrusion path
    $gcode .= $self->G0($path->points->[0], undef, 0, "move to first $description point")
        if !points_coincide($self->last_pos, $path->points->[0]);
    
    # compensate retraction
    $gcode .= $self->unretract if $self->retracted;
    
    my $area;  # mm^3 of extrudate per mm of tool movement 
    if ($path->role == EXTR_ROLE_BRIDGE) {
        my $s = $path->flow_spacing || $self->extruder->nozzle_diameter;
        $area = ($s**2) * PI/4;
    } else {
        my $s = $path->flow_spacing || ($self->layer ? $self->layer->flow->spacing : $Slic3r::flow->spacing);
        my $h = $path->depth_layers * $self->layer->height;
        $area = $self->extruder->mm3_per_mm($s, $h);
    }
    
    # calculate extrusion length per distance unit
    my $e = $self->extruder->e_per_mm3 * $area;
    
    # compensate retraction
	my $first_e = -1;
    if ($self->retracted) {
		my $distance_to_next_point = $path->points->[0]->distance_to($path->points->[1]);
		#print "first dist "; print unscale $distance_to_next_point;print " \n";
		my $unretract_to = Slic3r::Point->new($path->points->[1]);
		if ($distance_to_next_point > scale $self->layer->flow->width) {
			my $h = scale $self->layer->flow->width / $distance_to_next_point;
			#print "$h \n";
			$unretract_to = Slic3r::Point->new($path->points->[0]->x + $h * ($path->points->[1]->x - $path->points->[0]->x),$path->points->[0]->y + $h * ($path->points->[1]->y - $path->points->[0]->y));
			$first_e = $e * (1 - $h);
		} else {
			$first_e = 0;
		}

	    $gcode .= $self->unretract(unretract_move_to => $unretract_to)
	}
    
    # extrude arc or line
    my $Role =  (($path->role <= 3 || $path->role == 10) && $path->length <= &Slic3r::SMALL_PERIMETER_LENGTH) ? $path->role : EXTR_ROLE_SMALLPERIMETER;
    $self->speed( $role_speeds{$Role} || die "Unknown role: " . $Role );
    my $path_length = 0;
    if ($path->isa('Slic3r::ExtrusionPath::Arc')) {
        $path_length = $path->length;
        $gcode .= $self->G2_G3($path->points->[-1], $path->orientation, 
            $path->center, $e * unscale $path_length, $description);
    } else {
        foreach my $line ($path->lines) {
            my $line_length = $line->length;
            $path_length += $line_length;
            my $e_ = $first_e >= 0 ? $first_e : $e;
            $gcode .= $self->G1($line->b, undef, $e_ * unscale $line_length, $description . $path->role);
            $first_e = -1;
        }
    }
    
    if ($Slic3r::Config->cooling) {
        my $path_time = unscale($path_length) / $self->speeds->{$self->last_speed} * 60;
        if ($self->layer->id == 0) {
            $path_time = $Slic3r::Config->first_layer_speed =~ /^(\d+(?:\.\d+)?)%$/
                ? $path_time / ($1/100)
                : unscale($path_length) / $Slic3r::Config->first_layer_speed * 60;
        }
        $self->elapsed_time($self->elapsed_time + $path_time);
    }
    #set retract-to pos in case it is required by the next thread. - jmg
	#my $rpos = Slic3r::Point->new(($path->points->[1]->x + $path->points->[-2]->x) / 2,($path->points->[1]->y + $path->points->[-2]->y) / 2);
	##print "rpos X";print $rpos->x;print " Y";print $rpos->y;print "\n";
	##print unscale $path->points->[-1]->distance_to($rpos);print "\n";
	#my $m = 2;
	#$m = $m * -1 if (defined $path->role && ($path->role == 10 || $path->role == 3));
	#my $h = $m * scale $self->layer->flow->width / ($path->points->[-1]->distance_to($rpos) > $self->layer->flow->width ? $path->points->[-1]->distance_to($rpos) : 1);
	##print $h;print " role is ";print $path->role;print " \n";
	#my $retract_to = Slic3r::Point->new($path->points->[-1]->x + ($rpos->x - $path->points->[-1]->x) * $h, $path->points->[-1]->y + ($rpos->y - $path->points->[-1]->y) * $h);
    if ($path->role == 10 || $path->role == 2) {
   		#$self->retract_pos($self->old_start);
   		if($path->points->[-1]->distance_to($self->old_start) <= scale ($self->layer ? $self->layer->flow->spacing : $Slic3r::flow->spacing) * 3) {
   			$self->retract_pos($self->old_start);
   		} else {
   			my $h = scale ($self->layer ? $self->layer->flow->spacing : $Slic3r::flow->spacing) / $path->points->[-1]->distance_to($self->old_start);
   			$self->retract_pos(Slic3r::Point->new($path->points->[-1]->x + ($self->old_start->x - $path->points->[-1]->x) * $h, $path->points->[-1]->y + ($self->old_start->y - $path->points->[-1]->y) * $h));
   		}
   	#} else {
   	#	$self->retract_pos($retract_to);
   	}
    $self->prev_role($path->role);
    return $gcode;
}

sub retract {
    my $self = shift;
    my %params = @_;
    
    return "" unless $Slic3r::Config->retract_length > 0 
        && !$self->retracted;
    
    # prepare moves
    $self->speed('retract');
    my $retract = [undef, undef, -$Slic3r::Config->retract_length, "retract"];
    my $lift    = ($Slic3r::Config->retract_lift == 0 || defined $params{move_z})
        ? undef
        : [undef, $self->z + $Slic3r::Config->retract_lift, 0, 'lift plate during retraction'];
    
    my $gcode = "";
    if (($Slic3r::Config->g0 || $Slic3r::Config->gcode_flavor eq 'mach3') && $params{travel_to}) {
        if ($lift) {
            # combine lift and retract
            $lift->[2] = $retract->[2];
            $gcode .= $self->G0(@$lift);
        } else {
            # combine travel and retract
            my $travel = [$params{travel_to}, undef, $retract->[2], 'travel and retract'];
            $gcode .= $self->G0(@$travel);
        }
    } elsif (($Slic3r::Config->g0 || $Slic3r::Config->gcode_flavor eq 'mach3') && defined $params{move_z}) {
        # combine Z change and retraction
        my $travel = [undef, $params{move_z}, $retract->[2], 'change layer and retract'];
        $gcode .= $self->G0(@$travel);
    } else {
    	#print "retract move\n" if defined $params{retract_move_to};
    	$retract = [$params{retract_move_to}, undef, -$Slic3r::Config->retract_length, "retract"] if (defined $params{retract_move_to});
        $gcode .= $self->G1(@$retract);
        if (defined $params{move_z} && $Slic3r::Config->retract_lift > 0) {
            my $travel = [undef, $params{move_z} + $Slic3r::Config->retract_lift, 0, 'move to next layer (' . $self->layer->id . ') and lift'];
            $gcode .= $self->G0(@$travel);
            $self->lifted(1);
        } elsif ($lift) {
            $gcode .= $self->G1(@$lift);
        }
    }
    $self->retracted(1);
    $self->lifted(1) if $lift;
    
    # reset extrusion distance during retracts
    # this makes sure we leave sufficient precision in the firmware
    $gcode .= $self->reset_e if $Slic3r::Config->gcode_flavor !~ /^(?:mach3|makerbot)$/;
    
    return $gcode;
}

sub unretract {
    my $self = shift;
    my %params = @_;
    
    $self->retracted(0);
    my $gcode = "";
    
    if ($self->lifted) {
        $gcode .= $self->G0(undef, $self->z - $Slic3r::Config->retract_lift, 0, 'restore layer Z');
        $self->lifted(0);
    }
    
    $self->speed('retract');
    $gcode .= $self->G1(defined $params{unretract_move_to} ? $params{unretract_move_to} : undef, undef, ($Slic3r::Config->retract_length + $Slic3r::Config->retract_restart_extra), 
        "compensate retraction");
    
    return $gcode;
}

sub reset_e {
    my $self = shift;
    
    $self->extrusion_distance(0);
    return sprintf "G92 %s0%s\n", $Slic3r::Config->extrusion_axis, ($Slic3r::Config->gcode_comments ? ' ; reset extrusion distance' : '')
        if $Slic3r::Config->extrusion_axis && !$Slic3r::Config->use_relative_e_distances;
}

sub set_acceleration {
    my $self = shift;
    my ($acceleration) = @_;
    return "" unless $Slic3r::Config->acceleration;
    
    return sprintf "M201 E%s%s\n",
        $acceleration, ($Slic3r::Config->gcode_comments ? ' ; adjust acceleration' : '');
}

sub G0 {
    my $self = shift;
    return $self->G1(@_) if !($Slic3r::Config->g0 || $Slic3r::Config->gcode_flavor eq 'mach3');
    return $self->_G0_G1("G0", @_);
}

sub G1 {
    my $self = shift;
    return $self->_G0_G1("G1", @_);
}

sub _G0_G1 {
    my $self = shift;
    my ($gcode, $point, $z, $e, $comment) = @_;
    my $dec = $self->dec;
    
    if ($point && $point->distance_to($self->last_pos) > scale 0.05) {
        $gcode .= sprintf " X%.${dec}f Y%.${dec}f", 
            ($point->x * &Slic3r::SCALING_FACTOR) + $self->shift_x, 
            ($point->y * &Slic3r::SCALING_FACTOR) + $self->shift_y; #**
        $self->pen_pos($self->last_pos);
        $self->last_pos($point);
    }
    if (defined $z && $z != $self->z) {
        $self->z($z);
        $gcode .= sprintf " Z%.${dec}f", $z;
    }
    
    return $self->_Gx($gcode, $e, $comment);
}

sub G2_G3 {
    my $self = shift;
    my ($point, $orientation, $center, $e, $comment) = @_;
    my $dec = $self->dec;
    
    my $gcode = $orientation eq 'cw' ? "G2" : "G3";
    
    $gcode .= sprintf " X%.${dec}f Y%.${dec}f", 
        ($point->x * &Slic3r::SCALING_FACTOR) + $self->shift_x, 
        ($point->y * &Slic3r::SCALING_FACTOR) + $self->shift_y; #**
    
    # XY distance of the center from the start position
    $gcode .= sprintf " I%.${dec}f J%.${dec}f",
        ($center->[X] - $self->last_pos->[X]) * &Slic3r::SCALING_FACTOR,
        ($center->[Y] - $self->last_pos->[Y]) * &Slic3r::SCALING_FACTOR;
    
    $self->last_pos($point);
    return $self->_Gx($gcode, $e, $comment);
}

sub _Gx {
    my $self = shift;
    my ($gcode, $e, $comment) = @_;
    my $dec = $self->dec;
    
    # determine speed
    my $speed = ($e ? $self->speed : 'travel');
    
    # output speed if it's different from last one used
    # (goal: reduce gcode size)
    my $append_bridge_off = 0;
    if ($speed ne $self->last_speed) {
        if ($speed eq 'bridge') {
            $gcode = ";_BRIDGE_FAN_START\n$gcode";
        } elsif ($self->last_speed eq 'bridge') {
            $append_bridge_off = 1;
        }
        
        # apply the speed reduction for print moves on bottom layer
        my $speed_f = $self->speeds->{$speed};
        if ($e && $self->layer->id == 0 && $comment !~ /retract/) {
            $speed_f = $Slic3r::Config->first_layer_speed =~ /^(\d+(?:\.\d+)?)%$/
                ? ($speed_f * $1/100)
                : $Slic3r::Config->first_layer_speed * 60;
        }
        $gcode .= sprintf " F%.${dec}f", $speed_f;
        $self->last_speed($speed);
    }
    
    # output extrusion distance
    if ($e && $Slic3r::Config->extrusion_axis) {
        $self->extrusion_distance(0) if $Slic3r::Config->use_relative_e_distances;
        $self->extrusion_distance($self->extrusion_distance + $e);
        $self->total_extrusion_length($self->total_extrusion_length + $e);
        $gcode .= sprintf " %s%.5f", $Slic3r::Config->extrusion_axis, $self->extrusion_distance;
    }
    
    $gcode .= sprintf " ; %s", $comment if $comment && $Slic3r::Config->gcode_comments;
    if ($append_bridge_off) {
        $gcode .= "\n;_BRIDGE_FAN_END";
    }
    return "$gcode\n";
}

sub set_tool {
    my $self = shift;
    my ($tool) = @_;
    
    return "" if $self->extruder_idx == $tool;
    
    $self->extruder_idx($tool);
    return $self->retract
        . (sprintf "T%d%s\n", $tool, ($Slic3r::Config->gcode_comments ? ' ; change tool' : ''))
        . $self->reset_e
        . $self->unretract;
}

sub set_fan {
    my $self = shift;
    my ($speed, $dont_save) = @_;
    
    if ($self->last_fan_speed != $speed || $dont_save) {
        $self->last_fan_speed($speed) if !$dont_save;
        if ($speed == 0) {
            return sprintf "M107%s\n", ($Slic3r::Config->gcode_comments ? ' ; disable fan' : '');
        } else {
            return sprintf "M106 %s%d%s\n", ($Slic3r::Config->gcode_flavor eq 'mach3' ? 'P' : 'S'),
                (255 * $speed / 100), ($Slic3r::Config->gcode_comments ? ' ; enable fan' : '');
        }
    }
    return "";
}

sub set_temperature {
    my $self = shift;
    my ($temperature, $wait, $tool) = @_;
    
    return "" if $wait && $Slic3r::Config->gcode_flavor eq 'makerbot';
    
    my ($code, $comment) = $wait
        ? ('M109', 'wait for temperature to be reached')
        : ('M104', 'set temperature');
    return sprintf "$code %s%d %s; $comment\n",
        ($Slic3r::Config->gcode_flavor eq 'mach3' ? 'P' : 'S'), $temperature,
        (defined $tool && $tool != $self->extruder_idx) ? "T$tool " : "";
}

sub set_bed_temperature {
    my $self = shift;
    my ($temperature, $wait) = @_;
    
    my ($code, $comment) = $wait
        ? (($Slic3r::Config->gcode_flavor eq 'makerbot' ? 'M109'
            : $Slic3r::Config->gcode_flavor eq 'teacup' ? 'M109 P1'
            : 'M190'), 'wait for bed temperature to be reached')
        : ('M140', 'set bed temperature');
    return sprintf "$code %s%d ; $comment\n",
        ($Slic3r::Config->gcode_flavor eq 'mach3' ? 'P' : 'S'), $temperature;
}

1;
