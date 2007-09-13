package Sphinx::Config;

use warnings;
use strict;
use Carp qw/croak/;

=head1 NAME

Sphinx::Config - Sphinx search engine configuration file read/modify/write

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

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

    bless { }, ref($class) || $class;
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
			$current->{_data} = { %{$c->{_data}} };
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
		    $current->{_data}->{$1} = $2;
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
configuration data for the section.

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

If varname is given, then the single parameter of that name in the given section
is set to the specified value.

If a hash of name/value pairs is given, then any existing values are replaced
with the given hash.

If the section does not currently exist, a new one is appended.

Returns the hash containing the current data values for the given section.

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
	if ($var =~ m/^_/) {
	    $self->{_keys}->{$key}->{$var} = $value;
	}
	else {
	    $self->{_keys}->{$key}->{_data}->{$var} = $value;
	}
    }
    elsif (ref($var) eq "HASH") {
	$self->{_keys}->{$key}->{_data} = $var;
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
	my %data = %{ $c->{_data}};
	if ($c->{_inherit}) {
	    $s .= " : " . $c->{_inherit};
	    my $base = $self->get($c->{_type}, $c->{_inherit});
	    for (keys %$base) {
		delete $data{$_} if defined $data{$_} && ($base->{$_} eq $data{$_});
	    }
	}
	my $section = " {\n";
	$section .= '        ' . $_ . ' = ' . $data{$_} . "\n" for sort keys %data;
	$s .= $section . "}\n";
    }

    return $s;
}

=head2 save

    $c->save
    $c->save($filename, $comment)

Save the configuration to a file.

The comment is inserted literally, so each line should begin with '#'.

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
