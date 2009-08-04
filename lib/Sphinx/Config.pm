package Sphinx::Config;

use warnings;
use strict;
use Carp qw/croak/;
use Storable qw/dclone/;
use List::MoreUtils qw/firstidx/;

=head1 NAME

Sphinx::Config - Sphinx search engine configuration file read/modify/write

=head1 VERSION

Version 0.05

=cut

our $VERSION = '0.05';

=head1 SYNOPSIS

    use Sphinx::Config;

    my $c = Sphinx::Config->new();
    $c->parse($filename);
    $path = $c->get('index', 'test1', 'path');
    $c->set('index', 'test1', 'path', $path);
    $c->save($filename);
    ...

=head1 CONSTRUCTOR

=head2 new

    $c = Sphinx::Config->new;

=cut

sub new {
    my $class = shift;

    bless { _bestow => 1 }, ref($class) || $class;
}

=head2 preserve_inheritance

    $c->preserve_inheritance(0);
    $c->preserve_inheritance(1);
    $pi = $c->preserve_inheritance(1);

Set/get the current behaviour for preserving inherited values.  When
set to a non-zero value (the default), if a value is set in a parent
section, then it is automatically inherited by any child sections, and
when the configuration file is saved, values that are implicit through
inheritance are not shown.  When set to zero, each section is
considered standalone and a complete set of values is shown in the
saved file.

This flag may be enabled and disabled selectively for calls to set() and save().

=cut

sub preserve_inheritance {
    my $self = shift;
    $self->{_bestow} = shift if @_;

    return $self->{_bestow};
}

=head1 METHODS

=head2 parse

    $c->parse($filename)

Parse the given Sphinx configuration file.

Dies on error.

=cut

sub parse {
    my ($self, $filename) = @_;

    die "Sphinx::Config: $filename does not exist" unless -f $filename;

    my $fh;
    open($fh, "<$filename") or die "Sphinx::Config: cannot open $filename: $!";
    my $state = 'outer';
    my $seq = "section";
    my $line = 0;
    my $current;
    my @config;

    while (my $input = <$fh>) {
	chomp $input;
	$line++;
	# discard comments
	$input =~ s/\s*\#.*//o;
	while ($input =~ s!\\\s*$! !os && !eof($fh)) {
	    $input .= <$fh>;
	}

	while ($input) {
	    if ($state eq 'outer') {
		# split into tokens, fully consuming input line
		my @tokens = split(/\s+/, $input);
		$input = "";
		while (my $tok = shift @tokens) {
		    if ($seq eq "section") {
			if ($tok =~ m/^(?:source|index)$/o) {
			    $current = { _type => $tok };
			    push(@config, $current);
			    $seq = "name";
			}
			elsif ($tok =~ m/^(?:indexer|searchd|search)$/o) {
			    $current = { _type => $tok };
			    push(@config, $current);
			    $seq = "openblock";
			}
			else {
			    die "Sphinx::Config: $filename:$line: Expected section type, got '$tok'";
			}
		    }
		    elsif ($seq eq "name") {
			$current->{_name} = $tok;
			$seq = "openorinherit";
		    }
		    elsif ($seq eq "openorinherit") {
			if ($tok eq ':') {
			    $seq = "inherit";
			}
			else {
			    unshift(@tokens, $tok);
			    $seq = "openblock";
			}
		    }
		    elsif ($seq eq "inherit") {
			my $c;
			for (my $i = 0; $i < @config - 1; $i++) {
			    $c = $config[$i];
			    last if $c->{_name} eq $tok && $c->{_type} eq $current->{_type};
			}
			die "Sphinx::Config: $filename:$line: Base section '$tok' does not exist" unless (defined $c && $c != $current);
			$current->{_inherit} = $tok;
			push(@{$c->{_children} ||= []}, $current->{_name});
			$current->{_data} = dclone($c->{_data} || {});

			$current->{_inherited} = { map { $_ => 1 } keys %{$current->{_data}} };
			$seq = "openblock";
		    }
		    elsif ($seq eq "openblock") {
			die "Sphinx::Config: $filename:$line: expected '{'" unless $tok eq "{";
			$seq = "section";
			$state = "inner";
			# return any leftovers
			$input = join(" ", @tokens);
		    }
		}
	    }
	    elsif ($state eq "inner") {
		if ($input =~ s/^\s*\}//o) {
		    $state = "outer";
		    $current = undef;
		}
		elsif ($input =~ s/^\s*([\w]+)\s*=\s*(.*)\s*$//o) {
		    my $k = $1;
		    my $v = $2;
		    if (exists($current->{_data}->{$k}) && ! $current->{_inherited}->{$k}) {
			if (ref($current->{_data}->{$k}) eq 'ARRAY') {
			    # append to existing array
			    push(@{$current->{_data}->{$k}}, $v);
			}
			else {
			    # promote to array
			    $current->{_data}->{$k} = [ $current->{_data}->{$k}, $v ];
			}
		    }
		    else {
			# first or simple value
			$current->{_data}->{$k} = $v;
			$current->{_inherited}->{$k} = 0;
		    }
		}
		elsif ($input =~ s/^\s+$//o) {
		    # carry on
		}
		else {
		    die "Sphinx::Config: $filename:$line: expected name=value pair or end of section, got '$input'";
		}
	    }

	}	
    }
    close($fh);

    $self->{_config} = \@config;
    my %keys;
    for (@config) {
	$keys{$_->{_type} . ($_->{_name}?(' ' . $_->{_name}):'')} = $_;
    }

    $self->{_keys} = \%keys;
}


=head2 config

    $config = $c->config;

Get the parsed configuration data as an array of hashes, where each entry in the
array represents one section of the configuration, in the order as parsed or
constructed.

Each section is described by a hash with the following keys:

=over 4

=item * _type A mandatory key describing the section type (index, searchd etc)

=item * _name The name of the section, where applicable

=item * _inherited The name of the parent section, where applicable

=item * _data A hash containing the name/value pairs which hold the
configuration data for the section.  All values are simple data
elements, except where the same key can appear multiple times in the
configuration file with different values (such as in attribute
declarations), in which case the value is an array ref.

=item * _inherited A hash describing which data values have been inherited

=back

=cut

sub config {
    return shift->{_config};
}

=head2 get

    $value = $c->get($type, $name, $varname)
    $value = $c->get($type, $name)

Get the value of a configuration parameter.

If $varname is specified, the value of the named parameter from the section
identified by the type and name is returned as a scalar.  Otherwise, the hash containing all key/value pairs from the section is returned.

$name may be undef for sections that do not require a name (e.g. searchd,
indexer, search).

If the section cannot be found or the named parameter does not exist, undef is
returned.

=cut

sub get {
    my ($self, $type, $name, $var) = @_;

    my $key = $type;
    $key .= ' ' . $name if $name;

    my $current = $self->{_keys}->{$key};
    return undef unless $current;
    if ($var) {
	if ($var =~ m/^_/) {
	    return $current->{$var};
	}
	else {
	    return $current->{_data}->{$var};
	}
    }
    
    return $current->{_data};
}

=head2 set

    $c->set($type, $name, $varname, $value)
    $c->set($type, $name, \%values)

Set the value or values of a section in the configuration.

If varname is given, then the single parameter of that name in the
given section is set to the specified value.  If the value is an
array, multiple entries will be created in the output file for the
same key.

If a hash of name/value pairs is given, then any existing values are replaced
with the given hash.

If the section does not currently exist, a new one is appended.

To delete a name/value pair, set $value to undef.

Returns the hash containing the current data values for the given section.

See L<preserve_inheritance> for a description of how inherited values are handled.

=cut

sub set {
    my ($self, $type, $name, $var, $value) = @_;

    my $key = $type;
    $key .= ' ' . $name if $name;

    if (! $self->{_keys}->{$key}) {
	my $current = { _type => $type };
	$current->{_name} = $name if $name;
	push(@{$self->{_config}}, $current);
	$self->{_keys}->{$key} = $current;
    }
    if (! ref($var)) {
	if (! defined($var)) {
	    if (my $entry = delete $self->{_keys}->{$key}) {
		my $i = firstidx { $_ == $entry } @{$self->{_config}};
		splice(@{$self->{_config}}, $i, 1) if $i >= 0;
	    }
	}
	elsif ($var =~ m/^_/) {
	    if (defined $value) {
		$self->{_keys}->{$key}->{$var} = $value;
	    }
	    else {
		delete $self->{_keys}->{$key}->{$var};
	    }
	}
	else {
	    if (defined $value) {
		$self->{_keys}->{$key}->{_data}->{$var} = $value;
	    }
	    else {
		delete $self->{_keys}->{$key}->{_data}->{$var};
	    }
	    $self->{_keys}->{$key}->{_inherited}->{$var} = 0;

	    for my $child (@{$self->{_keys}->{$key}->{_children} || []}) {
		my $c = $self->{_keys}->{$type . ' ' . $child} or next;
		if ($self->{_bestow}) {
		    if ($c->{_inherited}->{$var}) {
			if (defined $value) {
			    $c->{_data}->{$var} = $value;
			}
			else {
			    delete $c->{_data}->{$var};
			}
		    }
		}
		else {
		    $c->{_inherited}->{$var} = 0;
		}
	    }
	}
    }
    elsif (ref($var) eq "HASH") {
	$self->{_keys}->{$key}->{_data} = dclone($var);
	$self->{_keys}->{$key}->{_inherited}->{$_} = 0 for keys %$var;
	for my $child (@{$self->{_keys}->{$key}->{_children} || []}) {
	    my $c = $self->{_keys}->{$type . ' ' . $child} or next;
	    for my $k (keys %$var) {
		if ($self->{_bestow}) {
		    $c->{_data}->{$k} = $var->{$k} if $c->{_inherited}->{$k};
		}
		else {
		    $c->{_inherited}->{$k} = 0;
		}
	    }
	}
    }
    else {
	croak "Must provide variable name or hash, not " . ref($var);
    }

    return $self->{_keys}->{$key}->{_data};
}



=head2 as_string

    $s = $c->as_string
    $s = $c->as_string($comment)

Returns the configuration as a string, optionally with a comment prepended.

The comment is inserted literally, so each line should begin with '#'.

=cut

sub as_string {
    my ($self, $comment) = @_;

    my $s = $comment ? "$comment\n" : "";
    for my $c (@{$self->{_config}}) {
	$s .= $c->{_type} . ($c->{_name} ? (" " . $c->{_name}) : '');
	my $data = dclone($c->{_data});
	if ($c->{_inherit} && $self->{_bestow}) {
	    $s .= " : " . $c->{_inherit};
	    my $base = $self->get($c->{_type}, $c->{_inherit});
	}
	my $section = " {\n";
	for my $k (sort keys %$data) {
	    next if $self->{_bestow} && $c->{_inherited}->{$k};
	    if (ref($data->{$k}) eq 'ARRAY') {
		for my $v (@{$data->{$k}}) {
		    $section .= '        ' . $k . ' = ' . $v . "\n";
		}
	    }
	    else {
		$section .= '        ' . $k . ' = ' . $data->{$k} . "\n";
	    }
	}
	$s .= $section . "}\n";
    }

    return $s;
}

=head2 save

    $c->save
    $c->save($filename, $comment)

Save the configuration to a file.

The comment is inserted literally, so each line should begin with '#'.

See L<preserve_inheritance> for a description of how inherited blocks are handled.

=cut

sub save {
    my ($self, $filename, $comment) = @_;

    my $fh;
    open($fh, ">$filename") or die("Sphinx::Config: Cannot open $filename for writing");
    print $fh $self->as_string($comment);
}

=head1 SEE ALSO

L<Sphinx::Search>

=head1 AUTHOR

Jon Schutz, C<< <jon at jschutz.net> >>

=head1 BUGS

Please report any bugs or feature requests to
C<bug-sphinx-config at rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Sphinx-Config>.
I will be notified, and then you'll automatically be notified of progress on
your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Sphinx::Config

You can also look for information at:

=over 4

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Sphinx-Config>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Sphinx-Config>

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Sphinx-Config>

=item * Search CPAN

L<http://search.cpan.org/dist/Sphinx-Config>

=back

=head1 ACKNOWLEDGEMENTS

=head1 COPYRIGHT & LICENSE

Copyright 2007 Jon Schutz, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

1; # End of Sphinx::Config
