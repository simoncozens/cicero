package Cicero::KP;
our $finishing;
our %widthcache;
our @nodes;
our @page;
our @output;
use Font::TTF::Font;
use Font::TTF::OpenTypeLigatures;
use strict;
use base 'Text::KnuthPlass';
use Text::Hyphen;
our $hyph = Text::Hyphen->new;
#our $hyph = Text::KnuthPlass::DummyHyphenator->new;

sub glueclass { "Cicero::KP::Glue" }
sub penaltyclass { "Cicero::KP::Penalty" }
my %ligcache;
our $spacefactor;
our %pagetotals;
our @thispage;

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

sub _add_space_justify {
    my ($self, $nodes_r, $final) = @_;
    if ($final) {
        push @{$nodes_r}, 
           $self->glueclass->new(
               width => 0,
               stretch => $self->infinity,
               shrink => 0),
           $self->penaltyclass->new(width => 0, penalty => -$self->infinity, flagged => 1);
    } else {
       push @{$nodes_r}, $self->glueclass->new(
               width => $self->{spacewidth} * $spacefactor / 1000,
               stretch => $self->{spacestretch},
               shrink => $self->{spaceshrink}
           );
   }
}


sub break_text_into_nodes {
    my ($self, $text, $t, $ff, $style) = @_;
    $self->{ligengine} = Font::TTF::OpenTypeLigatures->new($ff);
    my @nodes;
    $self->{emwidth}    = $self->measure->("M");
    $self->{spacewidth} = $self->measure->(" ");
    my @words = split /\s+/, $text;
    $self->{spacestretch} = $self->{spacewidth} * $self->space->{width} / $self->space->{stretch};
    $self->{spaceshrink} = $self->{spacewidth} * $self->space->{width} / $self->space->{shrink};
    my $font = $t->{' font'};
    our $lastglyph = 0;
    my $k;
    my $output = sub {
        my $l = shift;
        my $width = $widthcache{$l} ||= $font->wxByCId($l);
        $width -= $k if $k = $font->kernPairCid($lastglyph, $l);
        $width = $width / 1000 * $t->{' fontsize'};
        $lastglyph = $l;
        push @nodes, Cicero::KP::HBox->new(
            value => 
                { 
                    glyph     => pack("n*", $l),
                    fontname  => $Cicero::stash->get("fontname"),
                    color     => $Cicero::stash->get("color"),
                    debug     => chr $font->uniByCId($l)
                },
            height => $Cicero::stash->get("fontsize"),
            depth  => $Cicero::stash->get("lead")-$Cicero::stash->get("fontsize"),
            width => $width
        );
    };
    for (0..$#words) { 
        my $word = $words[$_];
        my @elems = $self->hyphenator->hyphenate($word);
        my $stream = $self->{ligengine}->stream($output);
        for (0..$#elems) { 
            my $w = $elems[$_];
            my @chars = 
                map { $font->cidByUni(ord $_) }
                    map { $_ eq "~" ? " " : $_ }
                    split //, $w;
            for (@chars) { $stream->($_); }
            $stream->(-1);
            if ($_ != $#elems) {
                Cicero::penalty(flagged => 1, penalty => $self->hyphenpenalty);
            }
            $self->alter_space($w);
        }
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

{ our $last_badness = ~0; 
sub page_builder {
    while (my $vbox = shift @output) {
        $pagetotals{height} += $vbox->height + $vbox->depth
            if $vbox->isa("Cicero::KP::VBox") or
               $vbox->isa("Cicero::KP::VGlue");
        if ($vbox->isa("Cicero::KP::Penalty")) {
            my $left = $Cicero::cursor_y - $pagetotals{height};
            my $badness = $left > 0 ? $left**3 : 10000;
            my $c = $badness < 10000 ? $vbox->penalty + $badness : 10000;
            if ($c > $last_badness) {
                shipout();
                $last_badness = ~0;
            } else { $last_badness = $c }
        }
        push @page, $vbox;
    }
}
}

sub shipout {
    $_->typeset for @page;
    print " [".$Cicero::stash->get("pageno")."]";
    @page = ();
    Cicero->newpage() unless $finishing;
    $pagetotals{height} = 0;
}

sub leave_hmode {
    my $self = shift;
    #pop @nodes while @nodes and 
    #    ($nodes[-1]->is_penalty or $nodes[-1]->is_glue);

    my $t = $self->_typesetter;
    $t->_add_space_justify(\@nodes,1);
    $t->tolerance($Cicero::stash->get("tolerance"));
    my @breakpoints = ();
    @breakpoints = $t->break(\@nodes);
    if (!@breakpoints) { die "Couldn't set text at this tolerance" }
    return unless @breakpoints;
    my @lines = $t->breakpoints_to_lines(\@breakpoints, \@nodes);
    for (0..$#lines) {
        shift @nodes for @{$lines[$_]->{nodes}};
        push @output, bless $lines[$_], "Cicero::KP::VBox";
        if ($_ == 0) {
            push @output, Cicero::KP::Penalty->new(penalty => 150);
        } elsif ($_ == $#lines-1) {
            push @output, Cicero::KP::Penalty->new(penalty => 150);
        } else {
            push @output, Cicero::KP::Penalty->new(penalty => 0);
        }
    }
    $self->page_builder();
}

sub finish {
    $finishing = 1;
    if (@nodes) { shift->leave_hmode }
    if (@page)  { shipout() }
    print "\n";
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
        $line->{nodes}[-1]->isa("Cicero::KP::Penalty")
        and !$line->{nodes}[-1]->flagged
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

package Cicero::KP::VGlue;
use base 'Cicero::KP::Glue';
sub depth { 0 }
1;
