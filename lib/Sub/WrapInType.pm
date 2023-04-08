package Sub::WrapInType;
use 5.010001;
use strict;
use warnings;
use parent 'Exporter';
use Class::InsideOut qw( register readonly id );
use Types::Standard -types;
use Type::Params qw( signature );
use Sub::Util qw( set_subname );
use namespace::autoclean;

our $VERSION = '0.07';
our @EXPORT  = qw( wrap_sub wrap_method install_sub install_method );

readonly params    => my %params;
readonly returns   => my %returns;
readonly code      => my %code;
readonly is_method => my %is_method;

my $TypeConstraint  = HasMethods[qw( check get_message )];
my $ParamsTypes     = $TypeConstraint | ArrayRef[$TypeConstraint] | Map[Str, $TypeConstraint];
my $ReturnTypes     = $TypeConstraint | ArrayRef[$TypeConstraint];
my $Options         = Dict[
  skip_invocant => Optional[Bool],
  check         => Optional[Bool],
];
my $DEFAULT_OPTIONS = +{
  skip_invocant => 0,
  check         => 1,
};

sub new {
  state $check = signature(
    method => 1,
    multi => [
      +{
        positional => [
          $ParamsTypes,
          $ReturnTypes,
          CodeRef,
          $Options, +{ default => sub { $DEFAULT_OPTIONS } }
        ],
      },
      +{
        named_to_list => 1,
        named => [
          params  => $ParamsTypes,
          isa     => $ReturnTypes,
          code    => CodeRef,
          options => $Options, +{ default => sub { $DEFAULT_OPTIONS } },
        ],
      },
    ],
  );
  my ($class, $params_types, $return_types, $code, $options) = $check->(@_);
  $options = +{ %$DEFAULT_OPTIONS, %$options };

  my $typed_code =
      $options->{check}
    ? $class->_create_typed_code($params_types, $return_types, $code, $options)
    : sub { $code->(@_) };

  my $self = bless $typed_code, $class;
  register($self);

  {
    my $addr = id $self;
    $params{$addr}    = $params_types;
    $returns{$addr}   = $return_types;
    $code{$addr}      = $code;
    $is_method{$addr} = !!$options->{skip_invocant};
  }

  $self;
}

sub _create_typed_code {
  my ($class, $params_types, $return_types, $code, $options) = @_;
  my $params_types_checker =
      ref $params_types eq 'ARRAY' ? signature(positional => $params_types)
    : ref $params_types eq 'HASH'  ? signature(named => [%$params_types], bless => 0)
    :                                signature(positional => [$params_types]);
  my $return_types_checker =
    ref $return_types eq 'ARRAY' ? signature(positional => $return_types)
    :                              signature(positional => [$return_types]);

  if ( ref $return_types eq 'ARRAY' ) {
    if ( $options->{skip_invocant} ) {
      sub {
        my @return_values = $code->( shift, $params_types_checker->(@_) );
        $return_types_checker->(@return_values);
        @return_values;
      };
    }
    else {
      sub {
        my @return_values = $code->( $params_types_checker->(@_) );
        $return_types_checker->(@return_values);
        @return_values;
      };
    }
  }
  else {
    if ( $options->{skip_invocant} ) {
      sub {
        my $return_value = $code->( shift, $params_types_checker->(@_) );
        $return_types_checker->($return_value);
        $return_value;
      };
    }
    else {
      sub {
        my $return_value = $code->( $params_types_checker->(@_) );
        $return_types_checker->($return_value);
        $return_value;
      };
    }
  }
}

sub _is_env_ndebug {
  $ENV{PERL_NDEBUG} || $ENV{NDEBUG};
}

sub wrap_sub {
  state $check = signature(
    message => << 'EOS',
USAGE: wrap_sub(\@parameter_types, $return_type, $subroutine)
    or wrap_sub(params => \@params_types, returns => $return_types, code => $subroutine)
EOS
    multi => [
      +{ positional => [ $ParamsTypes, $ReturnTypes, CodeRef ] },
      +{
        named_to_list => 1,
        named => [
          params => $ParamsTypes,
          isa    => $ReturnTypes,
          code   => CodeRef,
        ],
      },
    ],
  );
  my ($params_types, $return_types, $code) = $check->(@_);

  __PACKAGE__->new($params_types, $return_types, $code, +{ check => !_is_env_ndebug() });
}

sub wrap_method {
  state $check = signature(
    message => << 'EOS',
USAGE: wrap_method(\@parameter_types, $return_type, $subroutine)
    or wrap_method(params => \@params_types, returns => $return_types, code => $subroutine)
EOS
    multi => [
      +{ positional => [ $ParamsTypes, $ReturnTypes, CodeRef ] },
      +{
        named_to_list => 1,
        named => [
          params => $ParamsTypes,
          isa    => $ReturnTypes,
          code   => CodeRef,
        ],
      },
    ],
  );
  my ($params_types, $return_types, $code) = $check->(@_);

  my $options = +{
    skip_invocant => 1,
    check         => !_is_env_ndebug(),
  };
  __PACKAGE__->new($params_types, $return_types, $code, $options);
}

sub install_sub {
  state $check = multisig(
    +{ message => << 'EOS' },
USAGE: install_sub($name, \@parameter_types, $return_type, $subroutine)
    or install_sub(name => $name, params => \@params_types, returns => $return_types, code => $subroutine)
EOS
    [ Str, $ParamsTypes, $ReturnTypes, CodeRef ],
    compile_named(
      name   => Str,
      params => $ParamsTypes,
      isa    => $ReturnTypes,
      code   => CodeRef,
    ),
  );
  my ($name, $params_types, $return_types, $code) = do {
    my @args = $check->(@_);
    ${^_TYPE_PARAMS_MULTISIG} == 0 ? @args : @{ $args[0] }{qw( name params isa code )};
  };

  _install($name, wrap_sub($params_types, $return_types, $code), scalar caller);
}

sub install_method {
  state $check = multisig(
    +{ message => << 'EOS' },
USAGE: install_method($name, \@parameter_types, $return_type, $subroutine)
    or install_method(name => $name, params => \@params_types, returns => $return_types, code => $subroutine)
EOS
    [ Str, $ParamsTypes, $ReturnTypes, CodeRef ],
    compile_named(
      name   => Str,
      params => $ParamsTypes,
      isa    => $ReturnTypes,
      code   => CodeRef,
    ),
  );
  my ($name, $params_types, $return_types, $code) = do {
    my @args = $check->(@_);
    ${^_TYPE_PARAMS_MULTISIG} == 0 ? @args : @{ $args[0] }{qw( name params isa code )};
  };

  _install($name, wrap_method($params_types, $return_types, $code), scalar caller);
}

sub _install {
  my ($name, $code, $pkg) = @_;
  my $fullname = "${pkg}::${name}";
  {
    no strict 'refs';
    *{$fullname} = $code;
  }
  set_subname($fullname, $code);
}

1;

__END__

=encoding utf-8

=head1 NAME

Sub::WrapInType - Wrap the subroutine to validate the argument type and return type.

=head1 SYNOPSIS

  use Types::Standard -types;
  use Sub::WrapInType;

  my $sum = wrap_sub [ Int, Int ], Int, sub {
    my ($x, $y) = @_;
    $x + $y;
  };
  $sum->(2, 5);  # Returns 7
  $sum->('foo'); # Throws an exception

  my $subtract = wrap_sub [ Int, Int ], Int, sub {
    my ($x, $y) = @_;
    "$x - $y";
  };
  $subtract->(5, 2); # Returns string '5 - 2', error!

=head1 DESCRIPTION

Sub::WrapInType is wrap the subroutine to validate the argument type and return type.

=head1 FUNCTIONS

=head2 wrap_sub(\@parameter_types, $return_type, $subroutine)

If you pass type constraints of parameters, a return type constraint, and a subroutine to this function,
Returns the subroutine wrapped in the process of checking the arguments given in the parameter's type constraints and checking the return value with the return value's type constraint.

  my $sum = wrap_sub [Int, Int], Int, sub {
    my ($x, $y) = @_;
    $x + $y;
  };
  $sum->(2, 5);  # Returns 7
  $sum->('foo'); # Throws an exception (Can not pass string)

  my $wrong_return_value = wrap_sub [Int, Int], Int, sub {
    my ($x, $y) = @_;
    "$x + $y";
  };
  $wrong_return_value->(2, 5); # Throws an exception (The return value isn't an Integer)
  $sum->('foo');               # Throws an exception (Can not pass string)

The type constraint expects to be passed an object of Type::Tiny.

When the subroutine returns multiple return values, it is possible to specify multiple return type constraints.

  my $multi_return_values = wrap_sub [Int, Int], [Int, Int], sub {
    my ($x, $y) = @_;
    ($x, $y);
  };
  my ($x, $y) = $multi_return_values->(0, 1);

You can pass named parameters.

  my $sub = wrap_sub(
    params => [Int, Int],
    return => Int,
    code   => sub {
      my ($x, $y) = @_;
      $x + $y;
    },
  );

If the C<PERL_NDEBUG> or the C<NDEBUG> environment variable is true, the subroutine will not check the argument type and return type.

If subroutine returns array or hash, Sub::WrapInType will not be able to check the type as you intended.
You should rewrite the subroutine to returns array reference or hash reference.

Sub::WrapInType does not support wantarray.

=head2 wrap_method(\@parameter_types, $return_type, $subroutine)

This function skips the type check of the first argument:

  sub add {
    my $class = shift;
    my ($x, $y) = @_;
    $x + $y;
  }

  my $sub = wrap_method [Int, Int], Int, \&add;
  $sub->(__PACKAGE__, 1, 2); # => 3

=head2 install_sub($name, \@parameter_types, $return_type, $subroutine)

Install the wrapped subroutine into the current package.

  use Sub::WrapInType qw( install_sub );

  install_sub sum => [ Int, Int ] => Int, sub {
    my ($x, $y) = @_;
    $x + $y;
  };
  sum(2, 5);  # Returns 7
  sum('foo'); # Throws an exception

=head2 install_method($name, \@parameter_types, $return_type, $subroutine)

Install the wrapped method into the current package.

=head1 METHODS

=head2 new(\@parameter_types, $return_type, $subroutine, $options)

Constract a new Sub::WrapInType object.

  use Types::Standard -types;
  use Sub::WrapInType;
  my $wraped_sub = Sub::WrapInType->new([Int, Int] => Int, sub { $_[0] + $_[1] });

=head3 options

=over 2

=item *

B<< check >>

Default: true

The created subroutine check the argument type and return type.

If you don't want to check the argument type and return type, pass false.

=item *

B<< skip_invocant >>

Default: false

The created subroutine skips the type check of the first argument.

=back

=head1 LICENSE

Copyright (C) mp0liiu.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

mp0liiu E<lt>mpoliiu@cpan.orgE<gt>

=head1 SEE ALSE

L<Type::Params> exports the function wrap_subs. It check only parameters type.

=cut

