package npg_tracking::glossary::composition::serializable;

use Moose::Role;
use JSON::XS;
use namespace::autoclean;
use Digest::SHA qw/sha256_hex/;
use Digest::MD5 qw/md5_hex/;
use Carp;
use Readonly;
use Class::Load qw/load_class/;

use npg_tracking::glossary::rpt;

requires 'pack';
requires 'unpack';

our $VERSION = '0';

Readonly::Scalar my $COMPONENTS_ATTR_NAME    => 'components';
Readonly::Scalar my $COMPONENT_CLASS         => 'component_class';
Readonly::Scalar my $ENFORCE_COMPONENT_CLASS => 'enforce_component_class';
Readonly::Scalar my $FREEZE_WITH_CLASS_NAMES => 'with_class_names';
Readonly::Scalar my $CLASS_NAME_KEY          => '__CLASS__';

sub thaw {
  my ( $class, $json, @args ) = @_;

  if (!$json) {
    croak 'JSON string is required';
  }

  my $h = JSON::XS->new()->decode($json);

  my $component_class;
  my $enforce_component_class = 0;
  if (@args && scalar @args % 2 == 0) {
    my %ah = @args;
    $component_class         = $ah{$COMPONENT_CLASS};
    $enforce_component_class = $ah{$ENFORCE_COMPONENT_CLASS};
    if ($component_class) {
      delete $ah{$COMPONENT_CLASS};
      delete $ah{$ENFORCE_COMPONENT_CLASS};
      @args = %ah;
    }
  }

  #####
  # JSON string is a serialized composition or component object.
  #
  foreach my $component_h ( $h->{$COMPONENTS_ATTR_NAME} ? @{$h->{$COMPONENTS_ATTR_NAME}} : () ) {
    my $cclass = $component_h->{$CLASS_NAME_KEY};
    if ($cclass) {
      if ($component_class && $enforce_component_class
            && ($component_class ne $cclass)) {
        croak "Unexpected component class $cclass";
      }
      #####
      # The class name might be concatenated with package version.
      # A dash is used for concatenation. No way to know whether
      # this dash is not a part of the package name, meaning that
      # component classes should not have dashes in their package
      # name.
      #
      ($cclass) = split /-/smx, $cclass;
    } elsif ($component_class) {
      $cclass = $component_class;
    } else {
      croak "Component class unknown, try defining via $COMPONENT_CLASS option";
    }
    $component_h->{$CLASS_NAME_KEY} = $cclass;
    load_class $cclass; # Multiple attempts to load the same class are OK
  }

  return $class->unpack( $h, @args );
}

sub freeze {
  my ($self, @args) = @_;
  if ( $self->can('sort') ) {
    $self->sort();
  }
  if (@args && (@args != 2 || $args[0] ne $FREEZE_WITH_CLASS_NAMES)) {
    croak "Options not recognised, allowed option - $FREEZE_WITH_CLASS_NAMES";
  }
  return JSON::XS->new()->canonical(1)->encode(
    (@args && $args[1]) ? $self->pack() : $self->_pack_custom() );
}

sub freeze2rpt {
  my $self = shift;

  my $values = $self->_pack_custom();
  my $rpt_string;
  if ($values->{$COMPONENTS_ATTR_NAME}) {
    $rpt_string = npg_tracking::glossary::rpt
                    ->deflate_rpts($values->{$COMPONENTS_ATTR_NAME});
  } else {
    $rpt_string = npg_tracking::glossary::rpt->deflate_rpt($values);
  }

  return $rpt_string;
}

sub digest {
  my ($self, $digest_type) = @_;
  return $self->compute_digest($self->freeze(), $digest_type);
}

sub compute_digest {
  my ($self, $data, $digest_type) = @_;
  return ($digest_type && $digest_type eq 'md5') ?
      md5_hex $data : sha256_hex $data;
}

sub _pack_custom {
  my $self = shift;
  return _clean_pack($self->pack());
}

sub _clean_pack { # Recursive function
  my $old = shift;

  my $type = ref $old;
  if (!$type || $type ne 'HASH') {
    return $old;
  }

  my $values = {};
  while ( my ($k, $v) = each %{$old} ) {
     # Delete __CLASS__ key along with private attrs
    if (defined $v && $k !~ /\A_/smx) {
      # Treat components the same way
      if (ref $v eq 'ARRAY' && $k eq $COMPONENTS_ATTR_NAME) {
        my @clean = map { _clean_pack($_) } @{$v};
        $v = \@clean;
      }
      $values->{$k} = $v;
    }
  }

  return $values;
}

no Moose::Role;

1;
__END__

=head1 NAME

npg_tracking::glossary::composition::serializable

=head1 SYNOPSIS

  package my::package;

  use Moose;
  use namespace::autoclean;
  use MooseX::Storage;

  with Storage( 
    'traits' => ['OnlyWhenBuilt'],
    'format' => '=npg_tracking::glossary::composition::serializable' );
  
  has 'attr_a'  => (isa => 'Str');
  has 'attr_b'  => (isa => 'Int');
  has '_attr_c' => (isa => 'Int', default => 3,);

  __PACKAGE__->meta->make_immutable;

  1;

  package main;
  use my::package;
  
  my $p = my::package->new(attr_a => 'a', attr_b => 2);
  my json = $p->freeze();
  print $json; # prints {"attr_a":"a","attr_b":2}
               # note the absence of both the __CLASS__ key
               # and private attributes
  my $p1 = my::package->thaw($json);

=head1 DESCRIPTION

Custom JSON serialization format for MooseX::Storage framework.
Differences with MooseX::Storage::Format::JSON:
  - uses JSON::XS directly,
  - private attributes are not serialized,
  - the output does not contain the __CLASS__ key,
  - the above applies recursively to an array reference attribute called
    'components'.

=head1 SUBROUTINES/METHODS

=head2 thaw

Instantiates an object from a JSON string.

  my $c = my::package->thaw($json);

If the JSON string does not contain class names of some or all components,
the default thaw method fails. The component class to use where it's
missing can be supplied.

  my $c = my::package->thaw(
    $json,
    component_class => 'npg_tracking::glossary::composition::component::illumina');

If the enforce_component_class option is set to true, an error is reaised
if the class of any of the components is defined and is different from the
supplied component class.

  my $c = my::package->thaw(
    $json,
    enforce_component_class => 1,
    component_class => 'npg_tracking::glossary::composition::component::illumina');

=head2 freeze

Serializes object's public attributes to a canonical (ordered) JSON string.

  $p->freeze();

Example output:

  {"components":[{"id_run":27081,"position":1,"subset":"phix","tag_index":0}]}

This string does not contain class names of the components and, therefore,
cannot be deserialized without additional options passed to the thaw method.
For a more conventional serialization set with_class_names to a true value.

 $p->freeze(with_class_names => 1);

Example output:

 {"__CLASS__":"npg_tracking::glossary::composition","components":[{"__CLASS__":"npg_tracking::glossary::composition::component::illumina","id_run":27081,"position":1,"subset":"phix","tag_index":0}]}

=head2 freeze2rpt

Returns a serialization of the object to an rpt string representation.
If the object has 'components' attribute/method that returns a true value,
this value is serialized instead. It is expected that the objects that
are serialized satisfy the minimum requirements of the
npg_tracking::glossary::rpt->deflate_rpt method, otherwise this method
gives an error. See npg_tracking::glossary::rpt for details.

  $p->freeze2rpt();

=head2 digest

Returns a digest of the JSON serialization string for $self.

  $p->digest();      # sha256_hex digest
  $p->digest('md5'); # md5 digest

=head2 compute_digest

Returns a digest of an input string.

  $p->compute_digest($string);        # sha256_hex digest
  $p->compute_digest($string, 'md5'); # md5 digest

=head1 DIAGNOSTICS

=head1 CONFIGURATION AND ENVIRONMENT

=head1 DEPENDENCIES

=over

=item Moose::Role

=item JSON::XS

=item namespace::autoclean

=item Digest::SHA

=item Digest::MD5

=item Carp

=item Readonly

=item npg_tracking::glossary::rpt

=back

=head1 INCOMPATIBILITIES

=head1 BUGS AND LIMITATIONS

=head1 AUTHOR

Marina Gourtovaia E<lt>mg8@sanger.ac.ukE<gt>

=head1 LICENSE AND COPYRIGHT

Copyright (C) 2016 GRL

This file is part of NPG.

NPG is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.

=cut
