package Mojolicious::Plugin::Directory::Stylish;

# ABSTRACT: Serve static files from document root with directory index using Mojolicious templates
use strict;
use warnings;

use Cwd ();
use Encode ();
use DirHandle;
use Mojo::Base qw{ Mojolicious::Plugin };
use Mojolicious::Types;
use Mojo::Asset::File;

my $types = Mojolicious::Types->new;

sub register {
    my ( $self, $app, $args ) = @_;

    my $root        = Mojo::Home->new( $args->{root} || Cwd::getcwd );
    my $handler     = $args->{handler};
    my $index       = $args->{dir_index};
    my $enable_json = $args->{enable_json};

    my $css         = $args->{css} || 'style';
    my $render_opts = $args->{render_opts} || {};
    $render_opts->{template} = $args->{dir_template} || 'list';
    push @{ $app->renderer->classes }, __PACKAGE__;
    push @{ $app->static->classes }, __PACKAGE__;

    $app->hook(
        before_dispatch => sub {
            my $c = shift;

            return render_file( $c, $root ) if ( -f $root->to_string() );

            my $path = $root->rel_dir( Mojo::Util::url_unescape( $c->req->url->path ) );
            $handler->( $c, $path ) if ( ref $handler eq 'CODE' );

            if ( -f $path ) {
                render_file( $c, $path ) unless ( $c->tx->res->code );
            }
            elsif ( -d $path ) {
                if ( $index && ( my $file = locate_index( $index, $path ) ) ) {
                    return render_file( $c, $file );
                }

                $c->stash(css => $css),
                render_indexes( $c, $path, $render_opts, $enable_json )
                    unless ( $c->tx->res->code );
            }
        },
    );
    return $app;
}

sub locate_index {
    my $index = shift || return;
    my $dir   = shift || Cwd::getcwd;

    my $root  = Mojo::Home->new($dir);

    $index = ( ref $index eq 'ARRAY' ) ? $index : ["$index"];
    for (@$index) {
        my $path = $root->rel_file($_);
        return $path if ( -e $path );
    }
}

sub render_file {
    my ( $c, $file ) = @_;

    my $asset = Mojo::Asset::File->new(path => $file);
    $c->reply->asset($asset);
}

sub render_indexes {
    my ( $c, $dir, $render_opts, $enable_json ) = @_;

    my @files =
        ( $c->req->url eq '/' )
        ? ()
        : ( { url => '../', name => 'Parent Directory', size => '', type => '', mtime => '' } );

    my ( $current, $list ) = list_files( $c, $dir );
    push @files, @$list;

    $c->stash( files   => \@files );
    $c->stash( current => $current );

    my %respond = ( any => $render_opts );
    $respond{json} = { json => { files => \@files, current => $current } }
        if ($enable_json);

    $c->respond_to(%respond);
}

sub list_files {
    my ( $c, $dir ) = @_;

    my $current = Encode::decode_utf8( Mojo::Util::url_unescape( $c->req->url->path ) );

    return ( $current, [] ) unless $dir;

    my $dh = DirHandle->new($dir);
    my @children;
    while ( defined( my $ent = $dh->read ) ) {
        next if $ent eq '.' or $ent eq '..';
        push @children, Encode::decode_utf8($ent);
    }

    my @files;
    for my $basename ( sort { $a cmp $b } @children ) {
        my $file = "$dir/$basename";
        my $url  = Mojo::Path->new($current)->trailing_slash(0);
        push @{ $url->parts }, $basename;

        my $is_dir = -d $file;
        my @stat   = stat _;
        if ($is_dir) {
            $basename .= '/';
            $url->trailing_slash(1);
        }

        my $mime_type =
            ($is_dir)
            ? 'directory'
            : ( $types->type( get_ext($file) || 'txt' ) || 'text/plain' );
        my $mtime = Mojo::Date->new( $stat[9] )->to_string();

        push @files, {
            url   => $url,
            name  => $basename,
            size  => $stat[7] || 0,
            type  => $mime_type,
            mtime => $mtime,
        };
    }

    return ( $current, \@files );
}

sub get_ext {
    $_[0] =~ /\.([0-9a-zA-Z]+)$/ || return;
    return lc $1;
}

1;

=head1 SYNOPSIS

  use Mojolicious::Lite;
  plugin 'Directory::Stylish';
  app->start;

or

  > perl -Mojo -E 'a->plugin("Directory::Stylish")->start' daemon

=head1 DESCRIPTION

L<Mojolicious::Plugin::Directory::Stylish> is a static file server directory index a la Apache's mod_autoindex.

=head1 METHODS

L<Mojolicious::Plugin::Directory::Stylish> inherits all methods from L<Mojolicious::Plugin>.

=head1 OPTIONS

L<Mojolicious::Plugin::Directory::Stylish> supports the following options.

=head2 C<root>

  plugin 'Directory::Stylish' => { root => "/path/to/htdocs" };

Document root directory. Defaults to the current directory.

if root is a file, serve only root file.

=head2 C<dir_index>

  plugin 'Directory::Stylish' => { dir_index => [qw/index.html index.htm/] };

like a Apache's DirectoryIndex directive.

=head2 C<dir_template>

  plugin 'Directory::Stylish' => { dir_template => 'index' };

  # with 'render_opts' option
  plugin 'Directory::Stylish' => {
      dir_template => 'index',
      render_opts  => { format => 'html', handler => 'ep' },
  };

  ...

  __DATA__

  @@ index.html.ep
  % layout 'default';
  % title 'DirectoryIndex';
  <h1>Index of <%= $current %></h1>
  <ul>
  % for my $file (@$files) {
  <li><a href='<%= $file->{url} %>'><%== $file->{name} %></a></li>
  % }

  @@ layouts/default.html.ep
  <!DOCTYPE html>
  <html>
    <head><title><%= title %></title></head>
    <body><%= content %></body>
    %= include $css;
  </html>

a template name of index page.

"$files", "$current", and "$css" are passed in stash.

=over 3

=item $files: Array[Hash]

list of files and directories

=item $current: String

current path

=item $css: String

name of template with css that you want to include

=back

=head2 C<handler>

  use Text::Markdown qw{ markdown };
  use Path::Class;
  use Encode qw{ decode_utf8 };

  plugin 'Directory::Stylish' => {
      handler => sub {
          my ($c, $path) = @_;
          if ($path =~ /\.(md|mkdn)$/) {
              my $text = file($path)->slurp;
              my $html = markdown( decode_utf8($text) );
              $c->render( inline => $html );
          }
      }
  };

CODEREF for handle a request file.

if not rendered in CODEREF, serve as static file.

=head2 C<enable_json>

  # http://host/directory?format=json
  plugin 'Directory::Stylish' => { enable_json => 1 };

enable json response.

=head1 SEE ALSO

L<Mojolicious::Plugin::Directory>
L<Plack::App::Directory>

=head1 ORIGINAL AUTHOR

hayajo E<lt>hayajo@cpan.orgE<gt> - Original author of L<Mojolicious::Plugin::Directory>

=cut

__DATA__

@@ layouts/default.html.ep
<!DOCTYPE html>
<html>
  <head>
    <title><%= title %></title>
    <meta http-equiv="content-type" content="text/html; charset=utf-8" />
    %= include $css;
  </head>
  <body>

<%= content %>

  </body>
</html>


@@ list.html.ep
% title "Index of $current";
% layout 'default';
<hr />
<table>
  <tr>
    <th class='name'>Name</th>
    <th class='size'>Size</th>
    <th class='type'>Type</th>
    <th class='mtime'>Last Modified</th>
  </tr>
  % for my $file (@$files) {
  <tr>
    <td class='name'><a href='<%= $file->{url} %>'><%== $file->{name} %></a></td>
    <td class='size'><%= $file->{size} %></td>
    <td class='type'><%= $file->{type} %></td>
    <td class='mtime'><%= $file->{mtime} %></td>
  </tr>
  % }
</table>
<hr />


@@ style.html.ep
  <style type='text/css'>
table { width:100%%; }
.name { text-align:left; }
.size, .mtime { text-align:right; }
.type { width:11em; }
.mtime { width:15em; }
  </style>
