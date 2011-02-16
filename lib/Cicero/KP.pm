package Cicero::KP;
our %widthcache;
our @nodes;
our @output;
use Font::TTF::Font;
use strict;
use base 'Text::KnuthPlass';

use Text::Hyphen;
our $hyph = Text::Hyphen->new;
#our $hyph = Text::KnuthPlass::DummyHyphenator->new;

sub glueclass { "Cicero::KP::Glue" }
sub penaltyclass { "Cicero::KP::Penalty" }
my %ligcache;
our $spacefactor;
sub lig_table {
    my ($self, $ff) = @_;
    $ligcache{$ff} ||= do {
        my $f = Font::TTF::Font->open($ff);
        $f->read;
        $f->{GSUB}->read;
        my @ligtable;
        my @features = grep /liga/, 
            @{$f->{GSUB}{SCRIPTS}{latn}{DEFAULT}{FEATURES}};
        my @ligs = 
                    grep { $_->{TYPE} == 4 }
                    map { $f->{GSUB}{LOOKUP}[$_] }
                     map { @{ $f->{GSUB}{FEATURES}{$_}{LOOKUPS} } }
                      @features;
        for my $lig (@ligs) {
            for (@{$lig->{SUB}}) {
                while (my ($k, $v) = each %{$_->{COVERAGE}{val}}) {
                    for (@{$_->{RULES}[$v]}) {
                    push @{$ligtable[$k]}, 
                        join(",",@{$_->{MATCH}})." => ".join(",",@{$_->{ACTION}});
                    }
                }
            }
        }
        \@ligtable;
    }
}

sub alter_space {
    my $spacecode = 1000;
    my ($self, $word) = @_;
    if ($word =~ /(\.|!|\?)$/) { $spacecode = 3000 }
    if ($word =~ /[A-Z]$/)     { $spacecode = 999 }
    if ($word =~ /['"\)\]]$/)  { $spacecode = 0 }
    if ($word =~ /:$/)         { $spacecode = 2000 }
    if ($word =~ /;$/)         { $spacecode = 1500 }
    if ($word =~ /,$/)         { $spacecode = 1250 }
    if ($spacecode) { $spacefactor = $spacecode }
}

sub break_text_into_nodes {
    my ($self, $text, $t, $ff, $style) = @_;
    my $lig_table = $self->lig_table($ff);
    my @nodes;
    $self->{emwidth}    = $self->measure->("M");
    $self->{spacewidth} = $self->measure->(" ");
    my @words = split /\s+/, $text;
    $self->{spacestretch} = $self->{spacewidth} * $self->space->{width} / $self->space->{stretch};
    $self->{spaceshrink} = $self->{spacewidth} * $self->space->{width} / $self->space->{shrink};
    my $font = $t->{' font'};
    our $last = 0;
    my $add_word = sub { 
        my $word = shift;
        my @elems = $self->hyphenator->hyphenate($word);
        my $lastglyph = 0;
        for (0..$#elems) { 
            my $w = $elems[$_];
            my @chars = 
                map { $font->cidByUni(ord $_) }
                map { $_ eq "~" ? " " : $_ }
                split //, $w;
            while (@chars) {
                my $l = shift @chars;
                if ($lig_table->[$l]) { 
                    for my $ligrule (@{$lig_table->[$l]}) {
                        my ($k, $v) = split / => /, $ligrule;
                        my $length = split /,/,$k;
                        my @replace = split /,/,$v;
                        if ($k eq join ",", @chars[0..$length-1]) {
                            $l = shift @replace;
                            splice @chars, 0, $length, @replace; 
                        }
                    }
                }
                # Kern
                my $width = $widthcache{$l} ||= $font->wxByCId($l);
                if (my $k = $font->kernPairCid($last, $l)) { $width -= $k; warn "Kerned" }
                $width = $width / 1000 * $t->{' fontsize'};
                $last = $l;
                push @nodes, Cicero::KP::HBox->new(
                    value => 
                        { 
                            glyph     => pack("n*", $l),
                            fontname  => $Cicero::stash->get("fontname"),
                            color     => $Cicero::stash->get("color"),
                            debug     => $font->uniByCId($l)
                        },
                    height => $Cicero::stash->get("fontsize"),
                    depth  => $Cicero::stash->get("lead")-$Cicero::stash->get("fontsize"),
                    width => $width

                );
            }
            if ($_ != $#elems) {
                push @nodes, Cicero::KP::Penalty->new(
                    flagged => 1, penalty => $self->hyphenpenalty);
            }
            $self->alter_space($w);
        }
    };
     for (0..$#words) { my $word = $words[$_];
         $add_word->($word);
         $self->_add_space_justify(\@nodes,0);
     }
    return @nodes;
}

sub setpar {
    my ($self, $paragraph, $finalizing) = @_;
    use Encode qw/_utf8_on/;
    $paragraph =~ s/\n/ /g;
    _utf8_on($paragraph);
    my @lines;
    if (!@nodes) {
        push @nodes, 
            Cicero::KP::HBox->new( width => 0, value => { glyph => 0 });
        push @nodes, 
            Cicero::KP::Glue->new( width => $Cicero::stash->get("parindent"), stretch => 0, shrink => 0);
    }
    Cicero->setfont();
    push @nodes, $self->_typesetter->break_text_into_nodes($paragraph,
        $Cicero::text,PDF::API2::_findFont($Cicero::stash->get("fontname"))
    );
}

sub _typesetter {

    Cicero::KP->new(
        measure => sub { $Cicero::text->advancewidth(shift)},
    linelengths => $Cicero::stash->get("parshape"),
    hyphenator  => $hyph,
    );
}

sub flush {
    while (my $vbox = shift @output) {
        $vbox->typeset();
        # Bottom of page?
    }
}

sub leave_hmode {
    my $self = shift;
    pop @nodes while @nodes and 
        ($nodes[-1]->is_penalty or $nodes[-1]->is_glue);

    my $t = $self->_typesetter;
    push @nodes,
        Cicero::KP::Penalty->new(penalty => $t->infinity),
        Cicero::KP::Glue->new(width => 0, stretch => $t->infinity),
        Cicero::KP::Penalty->new(penalty => -$t->infinity)
        ;

    $t->tolerance($Cicero::stash->get("tolerance"));
    my @breakpoints = ();
    @breakpoints = $t->break(\@nodes);
    if (!@breakpoints) { die "Couldn't set text at this tolerance" }
    return unless @breakpoints;
    my @lines = $t->breakpoints_to_lines(\@breakpoints, \@nodes);
    for my $line (@lines) {
        shift @nodes for @{$line->{nodes}};
        push @output, bless $line, "Cicero::KP::VBox";
    }
    $self->flush();
}

sub finish {
    warn "Finishing";
    if (@nodes) { shift->leave_hmode }
}

package Cicero::KP::VBox;
use List::Util qw/max/;
sub depth { max map { $_->isa("Cicero::KP::HBox") && $_->depth } @{shift->{nodes}}; }
sub height { max map { $_->isa("Cicero::KP::HBox") && $_->height } @{shift->{nodes}}; }
sub typeset {
    my $line = shift;
    $Cicero::cursor_x = $Cicero::stash->get("left");
    return unless @{$line->{nodes}};
    # Discard the discardables
    while ($line->{nodes}[-1] and
        $line->{nodes}[-1]->isa("Cicero::KP::Glue")
        ) {
        pop @{$line->{nodes}}
    }
    for my $node (@{$line->{nodes}}) {
        #next unless $node;
        $node->typeset($line);
    }
    if ($line->{nodes}[-1]->is_penalty) { $Cicero::text->text("-") }
    $Cicero::cursor_y -= $line->depth + $line->height;
}
sub _txt { join "", map {$_->_txt} @{shift->{nodes}} }

package Cicero::KP::HBox;
use base 'Text::KnuthPlass::Box';
__PACKAGE__->mk_accessors(qw/height depth/);
my %fontcache;
sub _txt { return "[".$_[0]->value->{debug}."/".$_[0]->width."]"; }

sub typeset {
    my $node = shift;
    # Check setting the font
    my $v = $node->value;
    Cicero->setfont($v->{fontname}, $node->height, $v->{color}); 
    $Cicero::text->translate($Cicero::cursor_x,$Cicero::cursor_y);
    $Cicero::text->add($Cicero::font->text_cid($v->{glyph},$node->height));
    $Cicero::cursor_x += $node->width;
}

package Cicero::KP::Glue;
use base 'Text::KnuthPlass::Glue';

sub typeset {
    my $node = shift;
    my $line = shift;
    $Cicero::cursor_x += $node->width + $line->{ratio} * 
        ($line->{ratio} < 0 ? $node->shrink : $node->stretch);
}

package Cicero::KP::Penalty;
use base 'Text::KnuthPlass::Penalty';

sub typeset {}

1;

1;
