package Cicero::StreamParser;

sub parse {
    my ($self, $fh) = @_;
    $Cicero::stash ||= Template::Stash::Persistent->new();
    my $t = Template->new(STASH => $Cicero::stash, EVAL_PERL => 1);
    $t->process($fh,{},sub{});
    die $t->error if $t->error;
}

use Template;
# Monkeypatch Template. Don't try this at home
use Template::Directive;

*Template::Directive::template = sub {
    my ($class, $block) = @_;
    $block = pad($block, 2) if $PRETTY;

    return "sub { return '' }" unless $block =~ /\S/;

    return <<EOF;
sub {
    my \$context = shift || die "template sub called without context\\n";
    my \$stash   = \$context->stash;
    my \$output  = '';
    tie \$output, "Cicero::Outstream", \$stash;
    my \$_tt_error;
    
    eval { BLOCK: {
$block
    } };
    if (\$@) {
        \$_tt_error = \$context->catch(\$@, \\\$output);
        die \$_tt_error unless \$_tt_error->type eq 'return';
    }

    return \$output;
}
EOF
};

# Import various Cicero primitives into Template::Perl

for (qw(typeset glue)) {
    *{"Template::Perl::$_"} = *{"Cicero::$_"};
}
package Template::Stash::Persistent;
use base "Template::Stash";
sub clone { return shift }

package Cicero::Outstream;
sub TIESCALAR { bless {}, $_[0] }
use base 'Tie::Scalar';

sub FETCH { "" }
sub STORE { Cicero::typeset($_[1]) }

1;
