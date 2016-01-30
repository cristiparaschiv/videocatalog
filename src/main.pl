#!/bin perl

use strict;
use warnings;

use Data::Dumper;
use JSON;
use Gtk3 '-init';
use Glib 'TRUE', 'FALSE';
use File::Find;
use File::Basename;
use Scalar::Util qw(looks_like_number);
use DBI;

use threads;
use threads::shared;

use constant COLUMN_NAME => 0;
use constant COLUMN_LENGTH => 1;
use constant COLUMN_SIZE => 2;
use constant COLUMN_PATH => 3;
use constant COLUMN_MD5 => 4;

our $mainWindow;
our $mainBox;
our $sw;
our $tv;
our $picBox;
our $buttonsBox;
our $pictures;
our $nextButton;
our $prevButton;
our $playButton;
our $montButton;
our $deleteButton;
our $index;
our $imgs;
our $toplay;
our $header;
our $menu;

our $prefWindow;
our $prefBox;
our $sourcedirBox;
our $sourcedirText;
our $sourcedirButton;
our $sourcedirLabel;
our $thumbdirBox;
our $thumbdirText;
our $thumbdirButton;
our $thumbdirLabel;
our $prefapplyButton;
our $dirWindow;

our $progressWindow;
our $progressBox;
our $progressBar;

our $settings = {
	source_dir => "",
	thumb_dir => "",
};
our $tagBox;
our $addtagButton;
our $tagText;

my $driver = "SQLite";
my $database = $ENV{"HOME"} . "/.catalog.db";
my $dsn = "DBI:$driver:dbname=$database";
my $userid = '';
my $password = '';
my $dbh = DBI->connect($dsn, $userid, $password, {RaiseError => 1}) or &log($DBI::errstr);

my $config = $ENV{"HOME"} . "/.movie_catalog.json";
my $log = "/tmp/collection.log";
&get_settings();

my $source_dir = $settings->{source_dir};
my $thumb_dir = $settings->{thumb_dir};

my $data = {};
my $file_list = [];

### Load Data from DB
&load_data();

&log("Rendering main window.");
&render_window();
Gtk3->main();

sub load_data {
	$data = {};
	my $dbh = DBI->connect($dsn, $userid, $password, {RaiseError => 1}) or &log($DBI::errstr);
	my $query = qq(SELECT id, name, path, md5, size, length, pictures, attributes, tags FROM videos);
	my $sth = $dbh->prepare($query);
	my $rv = $sth->execute();
	while (my $row = $sth->fetchrow_hashref) {
		my $size = int($row->{size} / 1024 / 1024) . " MB";
		my $length = $row->{length} . " s";

		my @imgs = split(',', $row->{pictures});
		@imgs = sort @imgs;

		$data->{$row->{md5}} = {
			name => $row->{name},
			path => $row->{path},
			md5 => $row->{md5},
			size => $size,
			length => $length,
			imgs => \@imgs,
			tags => $row->{tags},
			attributes => $row->{attributes}
		};
	}
	
	if (keys %$data) {
		&log("Found video collection.");
	} else {
		&log("No video collection found. Scan the source directory.");
	}
}

sub log {
	my $message = shift;

	$message  = localtime() . "    $message\n";
	open my $fh, ">>", $log;
	print $fh $message;
	close $fh;
}

sub update_db {
	if ($settings->{source_dir} eq "") {
		return 0;
	}
	$progressWindow = Gtk3::Window->new();
	$progressWindow->set_title('Updating Video Database');
	$progressWindow->set_border_width(5);
	$progressWindow->set_default_size(500, 150);

	$progressBox = Gtk3::Box->new('vertical', 5);
	$progressBar = Gtk3::ProgressBar->new();
	$progressBar->set_valign('center');

	$progressBox->pack_start($progressBar, TRUE, TRUE, 5);

	$progressWindow->add($progressBox);
	$progressWindow->show_all;

	threads->create(
		sub {
			my $tid = threads->self->tid;
			&log("Starting update DB thread $tid.");


			find(\&get_data, $source_dir);
			&log("Found " . scalar @$file_list . " files in source directory.");
			&process_files();
			
			&load_data();
			&log("Ended thread $tid.");

			$progressWindow->close();
			#Refresh UI List
			my $model = set_model($data);
			$tv->set_model($model);
		}
	);
}

sub get_settings() {
	if (-e $config) {
		&log("Found configuration file $config.");
		open my $fh, "<", $config;
		my $json = <$fh>;
		close $fh;
		$settings = decode_json($json);
	} else {
		&log("Configuration file not found. Create empty one.");
		open my $fh, ">", $config;
		print $fh "{\"source_dir\":\"\",\"thumb_dir\":\"\"}";
		close $fh;
	}
}

sub process_files {
	my $index = 0;
	my $dbh = DBI->connect($dsn, $userid, $password, {RaiseError => 1}) or &log($DBI::errstr);
	my $query = "DELETE FROM videos";
	$dbh->do($query);

	foreach my $file (@$file_list) {
		my $filename = basename($file);

		my $info = "ffprobe -i '$file' -show_format -v quiet | sed -n 's/duration=//p'";
		my $duration = `$info`;
		my $size = -s $file;

		my $ratio = int($duration/5);

		my $md5 = "md5sum '$file' | awk '{print " . '$1' . "}'";
		my $md5sum = `$md5`;
		chop($md5sum);
		my $t_dir = $thumb_dir . "/" . $md5sum . "/";
		my $command = "ffmpeg -i '$file' -vf fps=1/$ratio -s 640x480 $t_dir" . 'img%03d.jpg';
		
		if ((! -d $t_dir) && (-s $file > 1000000)) {
			mkdir($t_dir);
			#system($command);
			for (1..6) {
				my $r = $_*17;
				my $c = "ffmpegthumbnailer -i '$file' -o $t_dir" . "img$_.jpg -t $r -q 5 -s 640";
				system($c);
			}
		}

		my $imgs = [];
		my $imgs_string = "";
		opendir(DIR, "$thumb_dir/$md5sum");
		while (my $file = readdir(DIR)) {
			my $filename = $t_dir . $file;
			if (! -d $filename ) {
				push @$imgs, "$filename";
				$imgs_string .= "$filename,";
			}
		}
		closedir(DIR);
		chop($imgs_string);

		$duration = int($duration);
		
		my $query = qq(INSERT INTO videos (name, path, md5, size, length, pictures, attributes, tags)VALUES ("$filename", "$file", "$md5sum", "$size", "$duration", "$imgs_string", '', ''));
		$dbh->do($query);
		
		$index++;
		my $proc = $index / scalar(@$file_list);
		$progressBar->set_fraction($proc);
		&log("Processed $index / " . scalar(@$file_list) . ".");
	}
}


sub get_data {
	my $filename = $_;
	my $file = $File::Find::name;

	if (-d $file) {
		return 0;
	}

	my $info = "ffprobe -i '$file' -show_format -v quiet | sed -n 's/duration=//p'";
	my $duration = `$info`;
	my $size = -s $file;

	if (looks_like_number($duration) && $size > 1000000) {
		push @$file_list, $file;
	}
}

sub enable_buttons {
	$nextButton->set_sensitive(TRUE);
	$prevButton->set_sensitive(TRUE);
	$playButton->set_sensitive(TRUE);
	$montButton->set_sensitive(TRUE);
	$deleteButton->set_sensitive(TRUE);
	$addtagButton->set_sensitive(TRUE);
	$tagText->set_sensitive(TRUE);
}

sub render_window {
	$mainWindow = Gtk3::Window->new('toplevel');
	$mainWindow->set_title('Movie Catalog');
	$mainWindow->signal_connect(destroy => sub {Gtk3->main_quit;});
	$mainWindow->set_border_width(5);
	$mainWindow->set_default_size(600,450);
	$mainWindow->set_resizable(FALSE);

	$header = Gtk3::HeaderBar->new;
	$header->set_show_close_button(TRUE);
	$header->set_title('Movie Catalog');
	$mainWindow->set_titlebar($header);

	my $headerBox = Gtk3::Box->new('horizontal', 5);

	$menu = Gtk3::Menu->new();
	my $mitem = Gtk3::MenuItem->new_with_label("Preferences");
	$mitem->signal_connect('activate' => \&preferences, TRUE);
	$menu->append($mitem);

	my $mitem2 = Gtk3::MenuItem->new_with_label("Scan library");
	$mitem2->signal_connect('activate' => \&update_db, TRUE);
	$menu->append($mitem2);

	my $mb = Gtk3::MenuButton->new();
	my $img = Gtk3::Image->new_from_icon_name('open-menu-symbolic', 'button');
	$mitem->show;
	$mitem2->show;
	$mb->set_popup($menu);
	$mb->add($img);
	$headerBox->pack_start($mb, TRUE, TRUE, 0);
	$header->pack_start($headerBox);

	$mainBox = Gtk3::Box->new('horizontal', 5);
	$mainBox->set_homogeneous(FALSE);
	$mainWindow->add($mainBox);

	$sw = Gtk3::ScrolledWindow->new(undef, undef);
	$sw->set_shadow_type('etched-in');
	$sw->set_policy('automatic', 'automatic');
	$sw->set_size_request(450, 600);
	$mainBox->pack_start($sw, FALSE, FALSE, 5);

	my $model = set_model($data);

	$tv = Gtk3::TreeView->new($model);
	$tv->set_rules_hint(TRUE);
	$tv->set_search_column(COLUMN_NAME);
	$tv->signal_connect(row_activated => sub {&action(@_);});
	$sw->add($tv);
	add_columns($tv);

	$picBox = Gtk3::Box->new('vertical', 5);

	$buttonsBox = Gtk3::Box->new('horizontal', 5);
	$pictures = Gtk3::Image->new();
	$pictures->set_size_request(640,580);
	

	$nextButton = Gtk3::Button->new_with_label('Next');
	$nextButton->set_sensitive(FALSE);
	$nextButton->signal_connect(clicked => sub {$index++; &pic}, TRUE);
	$prevButton = Gtk3::Button->new_with_label('Prev');
	$prevButton->set_sensitive(FALSE);
	$prevButton->signal_connect(clicked => sub {$index--; &pic}, TRUE);
	$playButton = Gtk3::Button->new_with_label('Play');
	$playButton->set_sensitive(FALSE);
	$playButton->signal_connect(clicked => \&play, TRUE);
	$montButton = Gtk3::Button->new_with_label('Montage');
	$montButton->set_sensitive(FALSE);
	$montButton->signal_connect(clicked => \&montage, TRUE);
	$deleteButton = Gtk3::Button->new_with_label('Delete');
	$deleteButton->set_sensitive(FALSE);
	$deleteButton->signal_connect(clicked => \&delete_video, TRUE);

	$buttonsBox->pack_start($prevButton, TRUE, TRUE, 5);
	$buttonsBox->pack_start($nextButton, TRUE, TRUE, 5);
	$buttonsBox->pack_start($playButton, TRUE, TRUE, 5);
	$buttonsBox->pack_start($montButton, TRUE, TRUE, 5);
	$buttonsBox->pack_start($deleteButton, TRUE, TRUE, 5);

	$tagBox = Gtk3::Box->new('horizontal', 5);
	$tagText = Gtk3::Entry->new();
	$tagText->set_sensitive(FALSE);
	$addtagButton = Gtk3::Button->new_with_label('Add Tag');
	$addtagButton->set_sensitive(FALSE);
	$addtagButton->signal_connect(clicked => \&add_tag, TRUE);
	$tagBox->pack_start($tagText, TRUE, TRUE, 5);
	$tagBox->pack_start($addtagButton, FALSE, FALSE, 5);

	$picBox->pack_start($buttonsBox, TRUE, TRUE, 5);
	$picBox->pack_start($pictures, TRUE, TRUE, 5);
	$picBox->pack_start($tagBox, TRUE, TRUE, 5);

	$mainBox->pack_start($picBox, FALSE, FALSE, 5);

	$mainWindow->show_all;
}

sub add_tag {

}

sub dirWindow {
	my $location = shift;

	$dirWindow = Gtk3::FileChooserDialog->new("Please select a folder", $prefWindow, "select-folder", "Cancel", 'cancel', "Select", 'ok' );
	$dirWindow->set_default_size(800,400);

	my $response = $dirWindow->run();
	my $dir = '';

	if ($response eq 'ok') {
		$dir = $dirWindow->get_filename();
	}

	if ($location eq 'source') {
		$sourcedirText->set_text($dir);
	} else {
		$thumbdirText->set_text($dir);
	}

	$dirWindow->destroy();
}

sub save_pref {
	$source_dir = $sourcedirText->get_text();
	$thumb_dir = $thumbdirText->get_text();

	$settings->{source_dir} = $source_dir;
	$settings->{thumb_dir} = $thumb_dir;

	open my $fh, ">", $config;
	my $json = encode_json($settings);
	print $fh $json;
	close $fh;

	$prefWindow->destroy();
}

sub preferences {
	$prefWindow = Gtk3::Window->new();
	$prefWindow->set_title('Preferences');
	$prefWindow->set_border_width(5);
	$prefWindow->set_default_size(400, 150);

	my $header = Gtk3::HeaderBar->new;
	$header->set_show_close_button(TRUE);
	$header->set_title('Preferences');
	$prefWindow->set_titlebar($header);

	$prefBox = Gtk3::Box->new('vertical', 5);
	$sourcedirBox = Gtk3::Box->new('horizontal', 5);
	$thumbdirBox = Gtk3::Box->new('horizontal', 5);

	$sourcedirText = Gtk3::Entry->new();
	$sourcedirText->set_text($settings->{source_dir});
	$thumbdirText = Gtk3::Entry->new();
	$thumbdirText->set_text($settings->{thumb_dir});
	$sourcedirButton = Gtk3::Button->new_with_label('...');
	$sourcedirButton->signal_connect(clicked => sub {&dirWindow('source');}, TRUE);
	$thumbdirButton = Gtk3::Button->new_with_label('...');
	$thumbdirButton->signal_connect(clicked => sub {&dirWindow('thumb');}, TRUE);

	$sourcedirBox->pack_start($sourcedirText, TRUE, TRUE, 5);
	$sourcedirBox->pack_start($sourcedirButton, FALSE, FALSE, 5);
	$thumbdirBox->pack_start($thumbdirText, TRUE, TRUE, 5);
	$thumbdirBox->pack_start($thumbdirButton, FALSE, FALSE, 5);

	$sourcedirLabel = Gtk3::Label->new();
	$sourcedirLabel->set_text('Video source directory:');
	$sourcedirLabel->set_halign('start');
	$thumbdirLabel = Gtk3::Label->new();
	$thumbdirLabel->set_text('Thumbnails destination directory:');
	$thumbdirLabel->set_halign('start');

	$prefBox->pack_start($sourcedirLabel, TRUE, TRUE, 5);
	$prefBox->pack_start($sourcedirBox, TRUE, TRUE, 5);
	$prefBox->pack_start($thumbdirLabel, TRUE, TRUE, 5);
	$prefBox->pack_start($thumbdirBox, TRUE, TRUE, 5);

	$prefapplyButton = Gtk3::Button->new_with_label('Apply');
	$prefapplyButton->signal_connect(clicked => \&save_pref, TRUE);
	$prefBox->pack_start($prefapplyButton, TRUE, TRUE, 5);

	$prefWindow->add($prefBox);

	$prefWindow->set_position('center');
	$prefWindow->set_transient_for($mainWindow);
	$prefWindow->set_modal(TRUE);
	$prefWindow->show_all;
}

sub montage {
	my $command = "montage ";

	foreach (@$imgs) {
		$command .= "$_ ";
	}

	$command .= "-geometry +3+3 /tmp/$$.jpg";
	system($command);
	$command = "xdg-open /tmp/$$.jpg";
	system($command);
}

sub play {
	print "To Play File $toplay\n";
	system("vlc '$toplay'");
}

sub delete_video {
	&log("Will delete video $toplay.");
	### REMOVE VIDEO AND THUMBS
}

sub pic {

	my $size = scalar @$imgs;
	if ($index > $size-1) {
		$index = 0;
	}

	if ($index < 0) {
		$index = $size-1;
	}
	$pictures->set_from_file($imgs->[$index]);
}

sub get_pic_list {
	my $model = shift;
	my $iter = shift;

	my $md5 = $model->get_value($iter, 4);

	if (! keys %{$data->{$md5}}) {
		&load_data();
	}

	my $imgs = $data->{$md5}->{imgs};

	return $imgs;
}

sub action {
	my $tv = shift;
	my $path = shift;
	my $column = shift;

	my $model = $tv->get_model();
	my $iter = $model->get_iter($path);

	if (!keys %$data) {
		&load_data;
	}

	$toplay = $model->get_value($iter, 3);
	&enable_buttons();
	$imgs = &get_pic_list($model, $iter);

	$index = 0;
	$pictures->set_from_file($imgs->[$index]);
}

#Name, Length, Size, Path, md5
sub set_model {
	my $data = shift;

	my $model = Gtk3::ListStore->new('Glib::String', 'Glib::String', 'Glib::String', 'Glib::String', 'Glib::String',);
	for my $item (keys %$data) {
		my $item = $data->{$item};
		my $iter = $model->append();
		$model->set($iter, COLUMN_NAME, $item->{name}, COLUMN_LENGTH, $item->{length}, COLUMN_SIZE, $item->{size}, COLUMN_PATH, $item->{path}, COLUMN_MD5, $item->{md5});
	}

	return $model;
}

sub add_columns {
	my $tv = shift;
	my $model = $tv->get_model();

	my $renderer = Gtk3::CellRendererText->new;
	my $column = Gtk3::TreeViewColumn->new_with_attributes('Name', $renderer, text => COLUMN_NAME);
	$column->set_sort_column_id(COLUMN_NAME);
	$column->set_resizable(TRUE);
	$tv->append_column($column);

	$renderer = Gtk3::CellRendererText->new;
	$column = Gtk3::TreeViewColumn->new_with_attributes('Length', $renderer, text => COLUMN_LENGTH);
	$column->set_sort_column_id(COLUMN_LENGTH);
	$column->set_resizable(TRUE);
	$tv->append_column($column);
	
	$renderer = Gtk3::CellRendererText->new;
	$column = Gtk3::TreeViewColumn->new_with_attributes('Size', $renderer, text => COLUMN_SIZE);
	$column->set_sort_column_id(COLUMN_SIZE);
	$column->set_resizable(TRUE);
	$tv->append_column($column);
	
	$renderer = Gtk3::CellRendererText->new;
	$column = Gtk3::TreeViewColumn->new_with_attributes('Path', $renderer, text => COLUMN_PATH);
	$column->set_sort_column_id(COLUMN_PATH);
	$column->set_resizable(TRUE);
	$column->set_sizing('fixed');
	$tv->append_column($column);
	
	$renderer = Gtk3::CellRendererText->new;
	$column = Gtk3::TreeViewColumn->new_with_attributes('Md5', $renderer, text => COLUMN_MD5);
	$column->set_sort_column_id(COLUMN_MD5);
	$column->set_resizable(TRUE);
	$tv->append_column($column);
}
